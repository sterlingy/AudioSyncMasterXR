#include "jam_audio_link.h"

#include "aoo/aoo.h"
#include "aoo/aoo_events.h"
#include "aoo/codec/aoo_opus.h"
#include "aoo/codec/aoo_pcm.h"
#include <godot_cpp/classes/audio_server.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <algorithm>
#include <cmath>

using namespace godot;

namespace {
constexpr int MAX_BLOCK = 4096;

// AOO's log goes to Godot's verbose output (run with --verbose to see it):
// it reports routine stream start/stop races as errors.
void AOO_CALL aoo_log(AooLogLevel level, const AooChar *msg) {
	UtilityFunctions::print_verbose("[aoo] ", String::utf8(msg));
}

void aoo_init_once() {
	static bool done = [] {
		AooSettings settings;
		settings.logFunc = &aoo_log;
		settings.memPoolSize = AOO_MEM_POOL_SIZE;
		aoo_initialize(&settings);
		return true;
	}();
	(void)done;
}

double ntp_seconds(AooNtpTime a, AooNtpTime b) { return aoo_ntpTimeDuration(a, b); }
} // namespace

// ---- Playback of one remote player's stream

int32_t JamNetStreamPlayback::_mix(AudioFrame *p_buffer, float, int32_t p_frames) {
	if (!peer || !peer->sink) {
		for (int i = 0; i < p_frames; i++) p_buffer[i] = AudioFrame{0.0f, 0.0f};
		return p_frames;
	}
	float pk = 0.0f;
	int done = 0;
	const AooNtpTime now = aoo_getCurrentNtpTime();
	while (done < p_frames) {
		const int n = std::min<int>(p_frames - done, (int)buf.size());
		AooSample *ch = buf.data();
		if (peer->sink->process(&ch, n, now, nullptr, nullptr) != kAooOk) std::fill(buf.begin(), buf.begin() + n, 0.0f);
		for (int i = 0; i < n; i++) {
			const float v = buf[i];
			p_buffer[done + i] = AudioFrame{v, v};
			pk = std::max(pk, std::fabs(v));
		}
		done += n;
	}
	if (pk > peer->peak.load(std::memory_order_relaxed)) peer->peak.store(pk, std::memory_order_relaxed);
	return p_frames;
}

Ref<AudioStreamPlayback> JamNetStream::_instantiate_playback() const {
	Ref<JamNetStreamPlayback> pb;
	pb.instantiate();
	pb->setup(peer);
	return pb;
}

// ---- Link

JamAudioLink::JamAudioLink() { aoo_init_once(); }

JamAudioLink::~JamAudioLink() { stop(); }

Error JamAudioLink::start(int port, int p_my_id) {
	stop();
	if (!sock.open((uint16_t)port)) {
		UtilityFunctions::push_error("JamAudioLink: can't open UDP port ", port);
		return ERR_CANT_OPEN;
	}
	my_id = p_my_id;
	source = AooSource::create(my_id);
	if (!source) return ERR_CANT_CREATE;
	source->setEventHandler(&JamAudioLink::source_event, this, kAooEventModePoll);
	setup_source(48000);
	running = true;
	net_thread = std::thread([this] { net_loop(); });
	return OK;
}

void JamAudioLink::stop() {
	capture.stop();
	if (running.exchange(false) && net_thread.joinable()) net_thread.join();
	{
		std::lock_guard<std::mutex> lock(peers_mutex);
		peers.clear();
	}
	source.reset();
	sock.close();
	sending = false;
}

void JamAudioLink::setup_source(int sample_rate) {
	source_rate = sample_rate;
	source->setup(1, sample_rate, MAX_BLOCK, 0);
	source->setBufferSize(0.05);
	apply_format();
	if (sending.load()) source->startStream(0, nullptr);
}

void JamAudioLink::apply_format() {
	if (!source) return;
	if (codec == "opus") {
		AooFormatOpus f;
		// 2.5 ms frames for small blocks, 5 ms otherwise.
		AooFormatOpus_init(&f, 1, 48000, block_size <= 128 ? 120 : 240, OPUS_APPLICATION_RESTRICTED_LOWDELAY);
		source->setFormat(f.header);
		AooSource_setOpusBitrate(source.get(), nullptr, opus_bitrate);
	} else {
		AooFormatPcm f;
		AooFormatPcm_init(&f, 1, 48000, block_size, codec == "pcm24" ? kAooPcmInt24 : kAooPcmInt16);
		source->setFormat(f.header);
	}
}

void JamAudioLink::add_peer(int peer_id, const String &ip, int port) {
	if (!running.load() || peer_id == my_id) return;
	remove_peer(peer_id);
	auto p = std::make_shared<JamPeerAudio>();
	p->id = peer_id;
	if (!jam::UdpSocket::make_addr(ip.utf8().get_data(), (uint16_t)port, p->addr)) {
		UtilityFunctions::push_error("JamAudioLink: bad address ", ip);
		return;
	}
	p->sink = AooSink::create(peer_id);
	const int mix_rate = (int)AudioServer::get_singleton()->get_mix_rate();
	p->sink->setup(1, mix_rate, MAX_BLOCK, 0);
	p->sink->setLatency(latency_ms / 1000.0);
	p->sink->setEventHandler(&JamAudioLink::sink_event, p.get(), kAooEventModePoll);
	{
		std::lock_guard<std::mutex> lock(peers_mutex);
		peers[peer_id] = p;
	}
	// They play us through their sink whose id is our id.
	AooEndpoint ep{&p->addr, (AooAddrSize)sizeof(p->addr), my_id};
	source->addSink(ep, kAooTrue);
}

void JamAudioLink::remove_peer(int peer_id) {
	std::shared_ptr<JamPeerAudio> p;
	{
		std::lock_guard<std::mutex> lock(peers_mutex);
		auto it = peers.find(peer_id);
		if (it == peers.end()) return;
		p = it->second;
		peers.erase(it);
	}
	if (source) {
		AooEndpoint ep{&p->addr, (AooAddrSize)sizeof(p->addr), my_id};
		source->removeSink(ep);
	}
	// A JamNetStream still playing keeps the sink alive until it's freed.
}

Ref<AudioStream> JamAudioLink::get_peer_stream(int peer_id) {
	std::lock_guard<std::mutex> lock(peers_mutex);
	auto it = peers.find(peer_id);
	if (it == peers.end()) return Ref<AudioStream>();
	Ref<JamNetStream> s;
	s.instantiate();
	s->setup(it->second);
	return s;
}

Dictionary JamAudioLink::get_peer_stats(int peer_id) {
	Dictionary d;
	std::shared_ptr<JamPeerAudio> p;
	{
		std::lock_guard<std::mutex> lock(peers_mutex);
		auto it = peers.find(peer_id);
		if (it != peers.end()) p = it->second;
	}
	if (!p) return d;
	d["streaming"] = p->streaming.load();
	d["rtt_ms"] = p->rtt.load() * 1000.0;
	d["underruns"] = p->underruns.load();
	d["peak"] = p->peak.exchange(0.0f);
	d["latency_ms"] = latency_ms;
	if (p->sink) {
		double fill = 0.0;
		AooEndpoint ep{&p->addr, (AooAddrSize)sizeof(p->addr), peer_id};
		if (p->sink->getBufferFillRatio(ep, fill) == kAooOk) d["buffer_fill"] = fill;
	}
	return d;
}

void JamAudioLink::poll() {
	if (!running.load()) return;
	if (source) source->pollEvents();
	std::lock_guard<std::mutex> lock(peers_mutex);
	for (auto &kv : peers) kv.second->sink->pollEvents();
}

void AOO_CALL JamAudioLink::source_event(void *, const AooEvent *, AooThreadLevel) {}

void AOO_CALL JamAudioLink::sink_event(void *user, const AooEvent *e, AooThreadLevel) {
	JamPeerAudio *p = (JamPeerAudio *)user;
	switch (e->type) {
		case kAooEventSourcePing: {
			const auto &ping = e->sourcePing;
			p->rtt = ntp_seconds(ping.t1, ping.t4) - ntp_seconds(ping.t2, ping.t3);
			break;
		}
		case kAooEventBufferUnderrun:
			p->underruns.fetch_add(1);
			break;
		case kAooEventStreamStart:
			p->streaming = true;
			break;
		case kAooEventStreamStop:
		case kAooEventSourceRemove:
			p->streaming = false;
			break;
		default:
			break;
	}
}

AooInt32 AOO_CALL JamAudioLink::send_fn(void *user, const AooByte *data, AooInt32 size, const void *address, AooAddrSize addrlen, AooFlag) {
	return ((JamAudioLink *)user)->sock.send(data, size, address, (int)addrlen);
}

void JamAudioLink::net_loop() {
	std::vector<uint8_t> buf(AOO_MAX_PACKET_SIZE + 64);
	while (running.load()) {
		if (sock.wait(1)) {
			sockaddr_in from{};
			int n;
			while ((n = sock.recv(buf.data(), (int)buf.size(), from)) > 0) {
				AooMsgType type;
				AooId id;
				AooInt32 offset;
				if (aoo_parsePattern(buf.data(), n, &type, &id, &offset) != kAooOk) continue;
				if (type == kAooMsgTypeSource) {
					if (id == my_id) source->handleMessage(buf.data(), n, &from, sizeof(from));
				} else if (type == kAooMsgTypeSink) {
					std::lock_guard<std::mutex> lock(peers_mutex);
					auto it = peers.find(id);
					if (it != peers.end()) it->second->sink->handleMessage(buf.data(), n, &from, sizeof(from));
				}
			}
		}
		source->send(&JamAudioLink::send_fn, this);
		std::lock_guard<std::mutex> lock(peers_mutex);
		for (auto &kv : peers) kv.second->sink->send(&JamAudioLink::send_fn, this);
	}
}

// ---- Input

PackedStringArray JamAudioLink::get_input_devices() {
	PackedStringArray out;
	for (const auto &n : jam::AudioCapture::list_devices()) out.push_back(String::utf8(n.c_str()));
	return out;
}

bool JamAudioLink::has_native_capture() { return jam::AudioCapture::supported(); }

void JamAudioLink::feed(const float *mono, int frames, int sample_rate) {
	if (!source || sample_rate != source_rate) return;
	static thread_local std::vector<float> scratch(MAX_BLOCK);
	const float g = input_gain.load(std::memory_order_relaxed);
	float pk = 0.0f;
	while (frames > 0) {
		const int n = std::min(frames, MAX_BLOCK);
		for (int i = 0; i < n; i++) {
			scratch[i] = mono[i] * g;
			pk = std::max(pk, std::fabs(scratch[i]));
		}
		if (sending.load(std::memory_order_relaxed)) {
			AooSample *ch = scratch.data();
			source->process(&ch, n, aoo_getCurrentNtpTime());
		}
		mono += n;
		frames -= n;
	}
	if (pk > input_peak.load(std::memory_order_relaxed)) input_peak.store(pk, std::memory_order_relaxed);
}

Error JamAudioLink::start_capture(int device, int channel) {
	if (!running.load()) return ERR_UNCONFIGURED;
	capture.stop();
	capture_ready = false; // until the source matches the device's rate
	if (!capture.start(device, channel, [this](const float *mono, int frames, int sr) {
			if (capture_ready.load(std::memory_order_acquire)) feed(mono, frames, sr);
		})) {
		return ERR_CANT_OPEN;
	}
	capture_device = device;
	capture_channel = channel;
	capture_period_ms = capture.period_ms();
	setup_source(capture.sample_rate());
	capture_ready.store(true, std::memory_order_release);
	return OK;
}

void JamAudioLink::stop_capture() {
	capture.stop();
	capture_period_ms = 0.0;
}

void JamAudioLink::push_input(const PackedVector2Array &frames, int sample_rate) {
	if (!source || capture.running()) return;
	if (sample_rate != source_rate) setup_source(sample_rate);
	static thread_local std::vector<float> mono;
	mono.resize(frames.size());
	for (int i = 0; i < frames.size(); i++) mono[i] = 0.5f * (frames[i].x + frames[i].y);
	feed(mono.data(), (int)mono.size(), sample_rate);
}

void JamAudioLink::set_sending(bool on) {
	if (!source || sending.load() == on) return;
	sending = on;
	if (on)
		source->startStream(0, nullptr);
	else
		source->stopStream(0);
}

void JamAudioLink::set_latency_ms(float ms) {
	latency_ms = std::clamp(ms, 2.0f, 500.0f);
	std::lock_guard<std::mutex> lock(peers_mutex);
	for (auto &kv : peers) kv.second->sink->setLatency(latency_ms / 1000.0);
}

void JamAudioLink::set_codec(const String &name, int bitrate) {
	codec = (name == "opus" || name == "pcm24") ? name : String("pcm16");
	opus_bitrate = std::clamp(bitrate, 16000, 512000);
	if (!source) return;
	// Formats change with the input stopped (setup and process must not overlap).
	const bool was = capture.running();
	capture.stop();
	apply_format();
	if (sending.load()) source->startStream(0, nullptr);
	if (was) start_capture(capture_device, capture_channel);
}

void JamAudioLink::set_block_size(int frames) {
	block_size = std::clamp(frames, 32, 1024);
	set_codec(codec, opus_bitrate);
}

void JamAudioLink::_bind_methods() {
	ClassDB::bind_method(D_METHOD("start", "port", "my_id"), &JamAudioLink::start);
	ClassDB::bind_method(D_METHOD("stop"), &JamAudioLink::stop);
	ClassDB::bind_method(D_METHOD("is_running"), &JamAudioLink::is_running);
	ClassDB::bind_method(D_METHOD("get_port"), &JamAudioLink::get_port);
	ClassDB::bind_method(D_METHOD("add_peer", "peer_id", "ip", "port"), &JamAudioLink::add_peer);
	ClassDB::bind_method(D_METHOD("remove_peer", "peer_id"), &JamAudioLink::remove_peer);
	ClassDB::bind_method(D_METHOD("get_peer_stream", "peer_id"), &JamAudioLink::get_peer_stream);
	ClassDB::bind_method(D_METHOD("get_peer_stats", "peer_id"), &JamAudioLink::get_peer_stats);
	ClassDB::bind_method(D_METHOD("poll"), &JamAudioLink::poll);
	ClassDB::bind_static_method("JamAudioLink", D_METHOD("get_input_devices"), &JamAudioLink::get_input_devices);
	ClassDB::bind_static_method("JamAudioLink", D_METHOD("has_native_capture"), &JamAudioLink::has_native_capture);
	ClassDB::bind_method(D_METHOD("start_capture", "device", "channel"), &JamAudioLink::start_capture, DEFVAL(-1), DEFVAL(-1));
	ClassDB::bind_method(D_METHOD("stop_capture"), &JamAudioLink::stop_capture);
	ClassDB::bind_method(D_METHOD("is_capturing"), &JamAudioLink::is_capturing);
	ClassDB::bind_method(D_METHOD("get_capture_error"), &JamAudioLink::get_capture_error);
	ClassDB::bind_method(D_METHOD("get_capture_period_ms"), &JamAudioLink::get_capture_period_ms);
	ClassDB::bind_method(D_METHOD("push_input", "frames", "sample_rate"), &JamAudioLink::push_input);
	ClassDB::bind_method(D_METHOD("set_sending", "on"), &JamAudioLink::set_sending);
	ClassDB::bind_method(D_METHOD("is_sending"), &JamAudioLink::is_sending);
	ClassDB::bind_method(D_METHOD("set_input_gain", "gain"), &JamAudioLink::set_input_gain);
	ClassDB::bind_method(D_METHOD("take_input_peak"), &JamAudioLink::take_input_peak);
	ClassDB::bind_method(D_METHOD("set_latency_ms", "ms"), &JamAudioLink::set_latency_ms);
	ClassDB::bind_method(D_METHOD("get_latency_ms"), &JamAudioLink::get_latency_ms);
	ClassDB::bind_method(D_METHOD("set_codec", "name", "bitrate"), &JamAudioLink::set_codec, DEFVAL(128000));
	ClassDB::bind_method(D_METHOD("get_codec"), &JamAudioLink::get_codec);
	ClassDB::bind_method(D_METHOD("set_block_size", "frames"), &JamAudioLink::set_block_size);
	ClassDB::bind_method(D_METHOD("get_block_size"), &JamAudioLink::get_block_size);
}
