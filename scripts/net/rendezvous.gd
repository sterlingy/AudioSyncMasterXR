class_name Rendezvous
extends RefCounted
## Talks to the connection server (server/asm_server.py): gets a room code for
## a host, finds the host's public addresses for a joiner, and registers this
## player's UDP sockets so others can reach them through home routers.
##
## The Session owns one while hosting or joining online and calls poll() every
## frame; it reports through the callbacks below. Registration packets for the
## session (ENet), clock and audio sockets are built here and sent by the
## Session from those sockets (register_packet()).

const DEFAULT_PORT := 47900
const RETRY := 0.5 # seconds between requests until answered
const GIVE_UP := 8.0

var server_ip := ""
var server_port := DEFAULT_PORT
var room := ""
var token := ""
var is_host := false
var error := ""
var host_eps := {} # kind -> [ip, port] (joiner)
var my_eps := {} # kind -> [ip, port], as the server sees our sockets
var punch_requests: Array = [] # host: [{token, eps}] waiting for the Session

var _ctl := PacketPeerUDP.new()
var _want := "" # the request we're waiting on: host / join / eps_host / eps_me
var _t_retry := 0.0
var _t_waited := 0.0
var _t_alive := 0.0


## Resolves "host[:port]". Returns "" or an error message.
func open(server: String) -> String:
	var parts := server.strip_edges().split(":")
	if parts.is_empty() or parts[0] == "":
		return "Set the connection server first."
	server_port = int(parts[1]) if parts.size() > 1 and parts[1].is_valid_int() else DEFAULT_PORT
	server_ip = parts[0] if parts[0].is_valid_ip_address() else IP.resolve_hostname(parts[0], IP.TYPE_IPV4)
	if server_ip == "":
		return "Couldn't find the connection server %s." % parts[0]
	_ctl.close()
	if _ctl.bind(0) != OK:
		return "Couldn't open a port to talk to the connection server."
	_ctl.set_dest_address(server_ip, server_port)
	return ""


func close() -> void:
	if token != "":
		_send({"op": "close", "room": room, "token": token})
	_ctl.close()
	room = ""
	token = ""
	_want = ""


func start_host() -> void:
	is_host = true
	_ask("host")


func start_join(code: String) -> void:
	is_host = false
	room = code.strip_edges().to_upper()
	_ask("join")


## Asks for our own public addresses (after our sockets registered).
func fetch_mine() -> void:
	_ask("eps_me")


func fetch_host() -> void:
	_ask("eps_host")


## The datagram a socket sends to the server so it learns that socket's public address.
func register_packet(kind: String) -> PackedByteArray:
	var b := "ASMR".to_ascii_buffer()
	b.append_array(JSON.stringify({"room": room, "token": token, "kind": kind}).to_utf8_buffer())
	return b


## Call every frame. Returns the name of what just completed ("hosted",
## "joined", "host_eps", "my_eps", "punch", "error"), or "".
func poll(delta: float) -> String:
	var done := ""
	while _ctl.is_bound() and _ctl.get_available_packet_count() > 0:
		var pkt := _ctl.get_packet()
		if _ctl.get_packet_ip() != server_ip:
			continue
		var msg: Variant = JSON.parse_string(pkt.get_string_from_utf8())
		if typeof(msg) != TYPE_DICTIONARY:
			continue
		var r := _handle(msg)
		if r != "":
			done = r
	if _want != "":
		_t_retry -= delta
		_t_waited += delta
		if _t_waited > GIVE_UP:
			error = "The connection server at %s:%d didn't answer." % [server_ip, server_port]
			_want = ""
			return "error"
		if _t_retry <= 0.0:
			_t_retry = RETRY
			_send_request()
	if token != "":
		_t_alive -= delta
		if _t_alive <= 0.0:
			_t_alive = 10.0
			_send({"op": "alive", "room": room, "token": token})
	return done


func _handle(msg: Dictionary) -> String:
	match str(msg.get("op", "")):
		"hosted":
			if _want == "host":
				room = str(msg.get("room", ""))
				token = str(msg.get("token", ""))
				_want = ""
				return "hosted"
		"joined":
			if _want == "join":
				token = str(msg.get("token", ""))
				_want = ""
				return "joined"
		"eps":
			var eps := _clean_eps(msg.get("eps", {}))
			if msg.get("who") == "host" and _want == "eps_host":
				host_eps = eps
				_want = ""
				return "host_eps"
			if msg.get("who") == "me" and _want == "eps_me":
				my_eps = eps
				_want = ""
				return "my_eps"
		"punch":
			if is_host:
				punch_requests.append({"token": str(msg.get("token", "")), "eps": _clean_eps(msg.get("eps", {}))})
				return "punch"
		"error":
			error = str(msg.get("msg", "Connection server error."))
			_want = ""
			return "error"
	return ""


static func _clean_eps(v: Variant) -> Dictionary:
	var out := {}
	if typeof(v) != TYPE_DICTIONARY:
		return out
	for k in ["enet", "clock", "audio"]:
		var e: Variant = v.get(k)
		if typeof(e) == TYPE_ARRAY and e.size() == 2 and str(e[0]).is_valid_ip_address():
			out[k] = [str(e[0]), clampi(int(e[1]), 1, 65535)]
	return out


func _ask(what: String) -> void:
	_want = what
	_t_retry = 0.0
	_t_waited = 0.0
	error = ""


func _send_request() -> void:
	match _want:
		"host":
			_send({"op": "host"})
		"join":
			_send({"op": "join", "room": room})
		"eps_host":
			_send({"op": "eps", "room": room, "token": token, "who": "host"})
		"eps_me":
			_send({"op": "eps", "room": room, "token": token, "who": "me"})


func _send(obj: Dictionary) -> void:
	if _ctl.is_bound():
		_ctl.put_packet(JSON.stringify(obj).to_utf8_buffer())
