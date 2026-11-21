#include "jam_audio_link.h"

#include "jam_synth.h"
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
double mix_rate_for_tap = 48000.0; // set when a link starts (AudioServer mix rate)
constexpr uint32_t NOTE_MAGIC = 0x314E5341; // "ASN1", as in session.gd
constexpr int NOTE_PKT = 30;
constexpr double MAX_NOTE_DELAY = 0.08;
enum { EVN_ON = 0, EVN_OFF, EVN_CC, EVN_BEND, EVN_HELLO, EVN_ACK };

template <class T>
void wr(uint8_t *b, int off, T v) { memcpy(b + off, &v, sizeof(T)); }
template <class T>
T rd(const uint8_t *b, int off) {
	T v;
	memcpy(&v, b + off, sizeof(T));
	return v;
}

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
	if (peer->tap_on.load(std::memory_order_acquire)) {
		// The voice as heard here, stamped with when it was mixed.
		const double t = jam::mono_seconds();
		float tmp[jam::TapBlock::FRAMES];
		for (int done = 0; done < p_frames; done += jam::TapBlock::FRAMES) {
			const int n = std::min<int>(p_frames - done, jam::TapBlock::FRAMES);
			for (int i = 0; i < n; i++) tmp[i] = p_buffer[done + i].left;
			peer->tap->write(tmp, nullptr, n, t + (double)done / mix_rate_for_tap, (int)mix_rate_for_tap);
		}
	}
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

JamAudioLink::~JamAudioLink() {
	stop();
	delete input_tap;
}

Error JamAudioLink::start(int port, int p_my_id) {
	stop();
	if (!sock.open((uint16_t)port)) {
		UtilityFunctions::push_error("JamAudioLink: can't open UDP port ", port);
		return ERR_CANT_OPEN;
	}
	my_id = p_my_id;
	mix_rate_for_tap = AudioServer::get_singleton()->get_mix_rate();
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

void JamAudioLink::set_my_id(int id) {
	my_id = id;
	if (source) source->setId(id);
}

void JamAudioLink::setup_source(int sample_rate) {
	if (sample_rate != source_rate || rec.empty()) {
		rec.assign((size_t)sample_rate * 64, 0.0f);
		rec_total = 0;
		rec_anchored = false;
		rec_seq = 0;
	}
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
	d["notes"] = p->notes.load();
	d["note_delay_ms"] = p->delay.load() * 1000.0;
	d["last_late_ms"] = p->last_late.load() * 1000.0;
	d["note_rtt_ms"] = p->note_rtt.load() * 1000.0;
	d["direct_in"] = p->direct_in.load();
	d["direct_out"] = p->direct_out.load();
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

// ---- Live notes

PackedByteArray JamAudioLink::pack_event(int sender, int type, int a, float value, double t, double at) {
	PackedByteArray b;
	b.resize(NOTE_PKT);
	uint8_t *p = b.ptrw();
	wr<uint32_t>(p, 0, NOTE_MAGIC);
	wr<uint32_t>(p, 4, (uint32_t)sender);
	p[8] = (uint8_t)type;
	p[9] = (uint8_t)(a & 0xff);
	wr<float>(p, 10, value);
	wr<double>(p, 14, t);
	wr<double>(p, 22, at);
	return b;
}

void JamAudioLink::route_notes(int peer_id, Object *synth) {
	JamSynth *js = Object::cast_to<JamSynth>(synth);
	std::lock_guard<std::mutex> lock(peers_mutex);
	auto it = peers.find(peer_id);
	if (it != peers.end()) it->second->core = js ? js->get_core() : nullptr;
}

void JamAudioLink::set_clock(double offset, double output_latency) {
	clock_offset = offset;
	out_latency = output_latency;
}

void JamAudioLink::send_event(int type, int a, float value, double at) {
	if (!running.load()) return;
	PackedByteArray pkt = pack_event(my_id, type, a, value, shared_now(), at);
	std::lock_guard<std::mutex> lock(peers_mutex);
	for (auto &kv : peers) sock.send(pkt.ptr(), NOTE_PKT, &kv.second->addr, sizeof(sockaddr_in));
}

void JamAudioLink::send_hellos() {
	PackedByteArray pkt = pack_event(my_id, EVN_HELLO, 0, 0.0f, shared_now(), NAN);
	std::lock_guard<std::mutex> lock(peers_mutex);
	for (auto &kv : peers) sock.send(pkt.ptr(), NOTE_PKT, &kv.second->addr, sizeof(sockaddr_in));
}

// Network thread. Plays a remote player's note at its stamp + that player's
// delay (95th percentile of recent lateness + 2 ms), straight into their
// synth's network queue: no game frame in between.
void JamAudioLink::handle_note_packet(const uint8_t *b, int n, const sockaddr_in &from) {
	if (n != NOTE_PKT || rd<uint32_t>(b, 0) != NOTE_MAGIC) return;
	const int sender = (int)rd<uint32_t>(b, 4);
	const int type = b[8], a = b[9];
	const float value = rd<float>(b, 10);
	const double t = rd<double>(b, 14), at = rd<double>(b, 22);
	std::lock_guard<std::mutex> lock(peers_mutex);
	auto it = peers.find(sender);
	if (it == peers.end()) return;
	JamPeerAudio &p = *it->second;
	const double now = shared_now();
	if (type == EVN_HELLO) {
		p.direct_in = true;
		PackedByteArray ack = pack_event(my_id, EVN_ACK, 0, 0.0f, t, NAN);
		sock.send(ack.ptr(), NOTE_PKT, &from, sizeof(from));
		return;
	}
	if (type == EVN_ACK) {
		p.direct_out = true;
		p.note_rtt = now - t;
		return;
	}
	if (!p.core) return;
	const double late = now - t;
	p.last_late = late;
	if (type == EVN_ON) {
		p.notes.fetch_add(1);
		p.lateness[p.late_pos] = (float)late;
		p.late_pos = (p.late_pos + 1) % 64;
		p.late_count = std::min(p.late_count + 1, 64);
		float tmp[64];
		memcpy(tmp, p.lateness, sizeof(float) * p.late_count);
		const int k = (int)(0.95 * (p.late_count - 1));
		std::nth_element(tmp, tmp + k, tmp + p.late_count);
		p.delay = std::clamp((double)tmp[k] + 0.002, 0.0, MAX_NOTE_DELAY);
	}
	const double when = t + (steady.load() ? p.delay.load() : 0.0);
	double target = when;
	jam::Event e;
	switch (type) {
		case EVN_ON:
			if (!std::isnan(at)) target = std::max(when, at - out_latency.load());
			p.shift[a] = (float)(target - when);
			e.type = jam::EV_NOTE_ON;
			e.a = a;
			e.value = value;
			break;
		case EVN_OFF:
			target = when + p.shift[a];
			p.shift[a] = 0.0f;
			e.type = jam::EV_NOTE_OFF;
			e.a = a;
			break;
		case EVN_CC:
			e.type = jam::EV_CC;
			e.a = a;
			e.value = value;
			break;
		case EVN_BEND:
			e.type = jam::EV_BEND;
			e.value = value;
			break;
		default:
			return;
	}
	e.frame = target <= now ? -1 : p.core->time_to_frame(target - clock_offset.load());
	p.core->push_net(e);
}

void JamAudioLink::net_loop() {
	std::vector<uint8_t> buf(AOO_MAX_PACKET_SIZE + 64);
	while (running.load()) {
		const double mono = jam::mono_seconds();
		if (mono >= next_hello) {
			next_hello = mono + 1.0;
			send_hellos();
		}
		if (sock.wait(1)) {
			sockaddr_in from{};
			int n;
			while ((n = sock.recv(buf.data(), (int)buf.size(), from)) > 0) {
				if (n == NOTE_PKT && rd<uint32_t>(buf.data(), 0) == NOTE_MAGIC) {
					handle_note_packet(buf.data(), n, from);
					continue;
				}
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

void JamAudioLink::feed(const float *mono, int frames, int sample_rate, double latency) {
	if (!source || sample_rate != source_rate || rec.empty()) return;
	// Recorder: the last sample of this block reached the converter about
	// `latency` ago; smooth that into a sample->time line (like SynthCore's DLL).
	{
		const int64_t total = rec_total.load(std::memory_order_relaxed);
		const size_t size = rec.size();
		const float g0 = input_gain.load(std::memory_order_relaxed);
		for (int i = 0; i < frames; i++) rec[(size_t)((total + i) % (int64_t)size)] = mono[i] * g0;
		const int64_t end = total + frames;
		const double t_end = jam::mono_seconds() - latency - input_offset.load(std::memory_order_relaxed);
		double t;
		if (!rec_anchored) {
			t = t_end;
			rec_anchored = true;
		} else {
			const double predicted = rec_at + (double)(end - rec_af) / sample_rate;
			const double err = t_end - predicted;
			t = (err > 0.05 || err < -0.05) ? t_end : predicted + err * 0.01;
		}
		rec_at = t;
		rec_af = end;
		const uint32_t s = rec_seq.load(std::memory_order_relaxed);
		rec_seq.store(s + 1, std::memory_order_release);
		rec_pub_t.store(t, std::memory_order_relaxed);
		rec_pub_f.store(end, std::memory_order_relaxed);
		rec_seq.store(s + 2, std::memory_order_release);
		rec_total.store(end, std::memory_order_release);
		if (input_tap_on.load(std::memory_order_acquire)) {
			// Stamped with when it was played (the recorder's line), not when it arrived.
			const double t0 = t - (double)frames / sample_rate;
			float tmp[jam::TapBlock::FRAMES];
			for (int done = 0; done < frames; done += jam::TapBlock::FRAMES) {
				const int k = std::min(frames - done, jam::TapBlock::FRAMES);
				for (int i = 0; i < k; i++) tmp[i] = mono[done + i] * g0;
				input_tap->write(tmp, nullptr, k, t0 + (double)done / sample_rate, sample_rate);
			}
		}
	}
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

Error JamAudioLink::start_capture(int device, int channel, bool exclusive) {
	if (!running.load()) return ERR_UNCONFIGURED;
	capture.stop();
	capture_ready = false; // until the source matches the device's rate
	if (!capture.start(device, channel, [this](const float *mono, int frames, int sr) {
			if (capture_ready.load(std::memory_order_acquire)) feed(mono, frames, sr, capture_latency);
		}, exclusive)) {
		return ERR_CANT_OPEN;
	}
	capture_device = device;
	capture_channel = channel;
	capture_exclusive = exclusive;
	capture_period_ms = capture.period_ms();
	capture_latency = capture_period_ms / 1000.0 + 0.001; // one buffer + converter
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
	feed(mono.data(), (int)mono.size(), sample_rate, 0.0);
}

// Main thread. Input between local times t0 and t1 (JamSynth.get_time()),
// as {samples: PackedFloat32Array, rate, complete}. Missing parts are silent.
Dictionary JamAudioLink::get_input_audio(double t0, double t1) {
	Dictionary d;
	PackedFloat32Array out;
	d["rate"] = source_rate;
	d["complete"] = false;
	if (rec.empty() || t1 <= t0 || t1 - t0 > 60.0) {
		d["samples"] = out;
		return d;
	}
	double at = 0.0;
	int64_t af = 0;
	bool ok = false;
	for (int tries = 0; tries < 8 && !ok; tries++) {
		const uint32_t s1 = rec_seq.load(std::memory_order_acquire);
		if (s1 == 0) break;
		if (s1 & 1) continue;
		at = rec_pub_t.load(std::memory_order_relaxed);
		af = rec_pub_f.load(std::memory_order_relaxed);
		ok = rec_seq.load(std::memory_order_acquire) == s1;
	}
	const int64_t f0 = af + (int64_t)std::llround((t0 - at) * source_rate);
	const int64_t n = (int64_t)std::llround((t1 - t0) * source_rate);
	out.resize(n);
	float *w = out.ptrw();
	const int64_t total = rec_total.load(std::memory_order_acquire);
	const int64_t size = (int64_t)rec.size();
	for (int64_t i = 0; i < n; i++) {
		const int64_t f = f0 + i;
		w[i] = (ok && f >= 0 && f < total && f >= total - size) ? rec[(size_t)(f % size)] : 0.0f;
	}
	d["samples"] = out;
	d["complete"] = ok && f0 >= std::max<int64_t>(0, total - size) && f0 + n <= total;
	return d;
}

jam::OutputTap *JamAudioLink::record_input(bool on) {
	if (on && !input_tap) input_tap = new jam::OutputTap();
	if (on) {
		jam::TapBlock b;
		while (input_tap->read(b)) {}
	}
	input_tap_on = on;
	return input_tap;
}

std::shared_ptr<JamPeerAudio> JamAudioLink::record_peer(int peer_id, bool on) {
	std::lock_guard<std::mutex> lock(peers_mutex);
	auto it = peers.find(peer_id);
	if (it == peers.end()) return nullptr;
	auto p = it->second;
	if (on && !p->tap) p->tap = new jam::OutputTap();
	if (on) {
		jam::TapBlock b;
		while (p->tap->read(b)) {}
	}
	p->tap_on = on;
	return p;
}

double JamAudioLink::get_input_time() const {
	if (rec_seq.load(std::memory_order_acquire) == 0) return -1.0;
	return rec_pub_t.load(std::memory_order_relaxed);
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
	if (was) start_capture(capture_device, capture_channel, capture_exclusive);
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
	ClassDB::bind_method(D_METHOD("start_capture", "device", "channel", "exclusive"), &JamAudioLink::start_capture, DEFVAL(-1), DEFVAL(-1), DEFVAL(false));
	ClassDB::bind_method(D_METHOD("is_capture_exclusive"), &JamAudioLink::is_capture_exclusive);
	ClassDB::bind_method(D_METHOD("stop_capture"), &JamAudioLink::stop_capture);
	ClassDB::bind_method(D_METHOD("is_capturing"), &JamAudioLink::is_capturing);
	ClassDB::bind_method(D_METHOD("get_capture_error"), &JamAudioLink::get_capture_error);
	ClassDB::bind_method(D_METHOD("get_capture_period_ms"), &JamAudioLink::get_capture_period_ms);
	ClassDB::bind_method(D_METHOD("push_input", "frames", "sample_rate"), &JamAudioLink::push_input);
	ClassDB::bind_method(D_METHOD("get_input_audio", "t0", "t1"), &JamAudioLink::get_input_audio);
	ClassDB::bind_method(D_METHOD("get_input_time"), &JamAudioLink::get_input_time);
	ClassDB::bind_method(D_METHOD("set_input_offset_ms", "ms"), &JamAudioLink::set_input_offset_ms);
	ClassDB::bind_method(D_METHOD("get_input_offset_ms"), &JamAudioLink::get_input_offset_ms);
	ClassDB::bind_method(D_METHOD("set_my_id", "id"), &JamAudioLink::set_my_id);
	ClassDB::bind_method(D_METHOD("set_sending", "on"), &JamAudioLink::set_sending);
	ClassDB::bind_method(D_METHOD("is_sending"), &JamAudioLink::is_sending);
	ClassDB::bind_method(D_METHOD("set_input_gain", "gain"), &JamAudioLink::set_input_gain);
	ClassDB::bind_method(D_METHOD("take_input_peak"), &JamAudioLink::take_input_peak);
	ClassDB::bind_method(D_METHOD("set_latency_ms", "ms"), &JamAudioLink::set_latency_ms);
	ClassDB::bind_method(D_METHOD("get_latency_ms"), &JamAudioLink::get_latency_ms);
	ClassDB::bind_method(D_METHOD("set_codec", "name", "bitrate"), &JamAudioLink::set_codec, DEFVAL(128000));
	ClassDB::bind_method(D_METHOD("get_codec"), &JamAudioLink::get_codec);
	ClassDB::bind_method(D_METHOD("set_block_size", "frames"), &JamAudioLink::set_block_size);
	ClassDB::bind_method(D_METHOD("route_notes", "peer_id", "synth"), &JamAudioLink::route_notes);
	ClassDB::bind_method(D_METHOD("set_clock", "offset", "output_latency"), &JamAudioLink::set_clock);
	ClassDB::bind_method(D_METHOD("set_steady_timing", "on"), &JamAudioLink::set_steady_timing);
	ClassDB::bind_method(D_METHOD("send_event", "type", "a", "value", "at"), &JamAudioLink::send_event);
	ClassDB::bind_static_method("JamAudioLink", D_METHOD("pack_event", "sender", "type", "a", "value", "t", "at"), &JamAudioLink::pack_event);
	ClassDB::bind_method(D_METHOD("get_block_size"), &JamAudioLink::get_block_size);
}
