class_name ClockLink
extends RefCounted
## Clock pings on their own UDP socket, handled on a thread.
##
## Over ENet, a ping waits for the next frame on each side before anyone
## looks at it, which skews the estimate by milliseconds. Here a thread blocks
## on the socket and stamps every packet the moment it arrives:
## - host: answers each ping at once with its shared-clock time;
## - client: the main thread sends it a TICK on the loopback socket when a
##   ping is due; it sends the ping, and stamps the answer on arrival.
## Samples go to the main thread through a mutex (ClockSync does the maths).

const MAGIC_PING := 0x50435341 # "ASCP"
const MAGIC_PONG := 0x4F435341 # "ASCO"
const MAGIC_TICK := 0x54435341 # "ASCT"
const MAGIC_QUIT := 0x51435341 # "ASCQ"

var is_host := false
var port := 0
## Host: this process's shared-clock offset (Transport.clock_offset), copied
## in by the main thread so the thread never touches nodes.
var host_offset := 0.0

var _sock := PacketPeerUDP.new()
var _poke := PacketPeerUDP.new()
var _thread: Thread
var _mutex := Mutex.new()
var _samples: Array = []
var _running := false
var _host_ip := ""
var _host_port := 0


func start_host(p_port: int) -> Error:
	is_host = true
	var err := _sock.bind(p_port)
	if err != OK:
		return err
	port = p_port
	_go()
	return OK


func start_client(host_ip: String, host_port: int) -> Error:
	is_host = false
	var err := _sock.bind(0)
	if err != OK:
		return err
	port = _sock.get_local_port()
	_host_ip = host_ip
	_host_port = host_port
	_go()
	return OK


func _go() -> void:
	_poke.set_dest_address("127.0.0.1", port)
	_running = true
	_thread = Thread.new()
	_thread.start(_loop)


## Client: asks the thread to send a ping now.
func ping() -> void:
	if _running and not is_host:
		_poke.put_packet(_word(MAGIC_TICK))


## Client: samples collected since the last call, as [t0, t1, t2].
func take_samples() -> Array:
	_mutex.lock()
	var out := _samples
	_samples = []
	_mutex.unlock()
	return out


func stop() -> void:
	if not _running:
		return
	_running = false
	_poke.put_packet(_word(MAGIC_QUIT))
	_thread.wait_to_finish()
	_sock.close()
	_poke.close()


static func _word(magic: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(20)
	b.encode_u32(0, magic)
	return b


func _loop() -> void:
	while _running:
		if _sock.wait() != OK:
			break
		while _sock.get_available_packet_count() > 0:
			var b := _sock.get_packet()
			var now := JamSynth.get_time()
			if b.size() != 20:
				continue
			var ip := _sock.get_packet_ip()
			var from_port := _sock.get_packet_port()
			var magic := b.decode_u32(0)
			if (magic == MAGIC_QUIT or magic == MAGIC_TICK) and not ip.ends_with("127.0.0.1"):
				continue # only this process pokes its own thread
			match magic:
				MAGIC_QUIT:
					return
				MAGIC_PING:
					if is_host:
						b.encode_u32(0, MAGIC_PONG)
						b.encode_double(12, now + host_offset)
						_sock.set_dest_address(ip, from_port)
						_sock.put_packet(b)
				MAGIC_TICK:
					if not is_host:
						var p := _word(MAGIC_PING)
						p.encode_double(4, JamSynth.get_time())
						_sock.set_dest_address(_host_ip, _host_port)
						_sock.put_packet(p)
				MAGIC_PONG:
					if not is_host:
						_mutex.lock()
						_samples.append([b.decode_double(4), b.decode_double(12), now])
						_mutex.unlock()
