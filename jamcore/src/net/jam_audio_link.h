// JamAudioLink: this player's audio stream to every other player, and their
// streams back, using AOO (Audio over OSC, BSD) on one UDP socket.
//
// - One AooSource (id = our player id) sends our captured input to every
//   peer. Each peer has an AooSink for us whose id is OUR player id, so a
//   sink id always names the player whose audio it plays.
// - For each remote player we keep an AooSink (id = their player id); its
//   output is a JamNetStream, an AudioStream to play with AudioStreamPlayer
//   or AudioStreamPlayer3D at their avatar. Nothing is mixed on a server.
// - A network thread receives packets (routing them by AOO pattern to the
//   source or the right sink) and sends what the source and sinks queued.
// - Input comes from native capture (WASAPI on Windows), or from Godot via
//   push_input() where native capture isn't available.
// - Every input sample also goes into a 64 s ring with a smoothed
//   sample->time mapping, so loopers can cut out exactly the bars that were
//   played (get_input_audio), whether or not we're in a session.
#pragma once
#include "audio_capture.h"
#include "udp_socket.h"
#include <godot_cpp/classes/audio_frame.hpp>
#include <godot_cpp/classes/audio_stream.hpp>
#include <godot_cpp/classes/audio_stream_playback.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <atomic>
#include <map>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

#include "engine/synth_core.h"
#include "aoo/aoo_sink.hpp"
#include "aoo/aoo_source.hpp"

namespace godot {

struct JamPeerAudio {
	int id = 0;
	sockaddr_in addr{};
	AooSink::Ptr sink;
	std::atomic<float> peak{0.0f};
	std::atomic<int> underruns{0};
	std::atomic<double> rtt{-1.0};
	std::atomic<float> loss{0.0f};
	std::atomic<bool> streaming{false};

	// Live notes (network thread only, except the atomics).
	std::shared_ptr<jam::SynthCore> core; // their instrument here; set via route_notes()
	float lateness[64] = {};
	int late_count = 0, late_pos = 0;
	float shift[256] = {}; // per note: how much later than stamp+delay its note-on was placed
	std::atomic<double> delay{0.0};
	std::atomic<double> last_late{0.0};
	std::atomic<double> note_rtt{-1.0};
	std::atomic<int> notes{0};
	std::atomic<bool> direct_in{false}, direct_out{false};

	// Jam recording of this voice (created once, kept for the peer's lifetime).
	jam::OutputTap *tap = nullptr;
	std::atomic<bool> tap_on{false};
	~JamPeerAudio() { delete tap; }
};

class JamNetStreamPlayback : public AudioStreamPlayback {
	GDCLASS(JamNetStreamPlayback, AudioStreamPlayback)
	std::shared_ptr<JamPeerAudio> peer;
	std::vector<float> buf;
	bool playing = false;

protected:
	static void _bind_methods() {}

public:
	void setup(const std::shared_ptr<JamPeerAudio> &p) {
		peer = p;
		buf.resize(4096);
	}
	void _start(double) override { playing = true; }
	void _stop() override { playing = false; }
	bool _is_playing() const override { return playing; }
	int32_t _mix(AudioFrame *p_buffer, float p_rate_scale, int32_t p_frames) override;
};

class JamNetStream : public AudioStream {
	GDCLASS(JamNetStream, AudioStream)
	std::shared_ptr<JamPeerAudio> peer;

protected:
	static void _bind_methods() {}

public:
	void setup(const std::shared_ptr<JamPeerAudio> &p) { peer = p; }
	Ref<AudioStreamPlayback> _instantiate_playback() const override;
	String _get_stream_name() const override { return "JamNetStream"; }
	double _get_length() const override { return 0.0; }
	bool _is_monophonic() const override { return true; }
};

class JamAudioLink : public RefCounted {
	GDCLASS(JamAudioLink, RefCounted)

	jam::UdpSocket sock;
	std::thread net_thread;
	std::atomic<bool> running{false};
	int my_id = 0;
	AooSource::Ptr source;
	std::mutex peers_mutex; // guards the map (main + network thread); not used on audio threads
	std::map<int, std::shared_ptr<JamPeerAudio>> peers;

	jam::AudioCapture capture;
	std::atomic<bool> capture_ready{false};
	int capture_device = -1;
	int capture_channel = -1;
	bool capture_exclusive = false;
	std::atomic<bool> sending{false};
	std::atomic<float> input_peak{0.0f};
	std::atomic<float> input_gain{1.0f};
	int source_rate = 0;
	float latency_ms = 15.0f;
	String codec = "pcm16";
	int opus_bitrate = 128000;
	int block_size = 128;
	double capture_period_ms = 0.0;

	// Live notes: 30-byte packets (same layout as Session.pack) on the audio socket.
	std::atomic<double> clock_offset{0.0}; // Transport.clock_offset
	std::atomic<double> out_latency{0.0};
	std::atomic<bool> steady{true};
	double next_hello = 0.0;
	double shared_now() const { return jam::mono_seconds() + clock_offset.load(std::memory_order_relaxed); }
	void handle_note_packet(const uint8_t *b, int n, const sockaddr_in &from);
	void send_hellos();

	void net_loop();
	void setup_source(int sample_rate);
	void apply_format();
	void feed(const float *mono, int frames, int sample_rate, double latency);

	// Input recorder (writer: whichever thread feeds; reader: main thread).
	std::vector<float> rec;
	std::atomic<int64_t> rec_total{0};
	bool rec_anchored = false;
	double rec_at = 0.0;
	int64_t rec_af = 0;
	std::atomic<uint32_t> rec_seq{0};
	std::atomic<double> rec_pub_t{0.0};
	std::atomic<int64_t> rec_pub_f{0};
	std::atomic<double> input_offset{0.0};
	jam::OutputTap *input_tap = nullptr;
	std::atomic<bool> input_tap_on{false};
	double capture_latency = 0.0;
	static AooInt32 AOO_CALL send_fn(void *user, const AooByte *data, AooInt32 size, const void *address, AooAddrSize addrlen, AooFlag flags);
	static void AOO_CALL source_event(void *user, const AooEvent *e, AooThreadLevel level);
	static void AOO_CALL sink_event(void *user, const AooEvent *e, AooThreadLevel level);

protected:
	static void _bind_methods();

public:
	JamAudioLink();
	~JamAudioLink();

	Error start(int port, int p_my_id);
	void set_my_id(int id);
	void stop();
	bool is_running() const { return running.load(); }
	int get_port() const { return sock.get_port(); }

	void add_peer(int peer_id, const String &ip, int port);
	void remove_peer(int peer_id);
	Ref<AudioStream> get_peer_stream(int peer_id);
	Dictionary get_peer_stats(int peer_id);
	void poll();

	static PackedStringArray get_input_devices();
	static bool has_native_capture();
	Error start_capture(int device, int channel, bool exclusive = false);
	bool is_capture_exclusive() const { return capture.is_exclusive(); }
	void stop_capture();
	bool is_capturing() const { return capture.running(); }
	String get_capture_error() const { return String(capture.error().c_str()); }
	double get_capture_period_ms() const { return capture_period_ms; }
	void push_input(const PackedVector2Array &frames, int sample_rate);
	Dictionary get_input_audio(double t0, double t1);
	double get_input_time() const; // local time of the newest recorded sample (-1 if none)
	void set_input_offset_ms(float ms) { input_offset = ms / 1000.0; }
	// C++ (jam recorder): taps for our input and a peer's voice; null if unknown.
	jam::OutputTap *record_input(bool on);
	std::shared_ptr<JamPeerAudio> record_peer(int peer_id, bool on);
	float get_input_offset_ms() const { return (float)(input_offset.load() * 1000.0); }

	void set_sending(bool on);
	bool is_sending() const { return sending.load(); }
	void set_input_gain(float g) { input_gain = g; }
	float take_input_peak() { return input_peak.exchange(0.0f); }
	void set_latency_ms(float ms);
	float get_latency_ms() const { return latency_ms; }
	void set_codec(const String &name, int bitrate);
	String get_codec() const { return codec; }
	void set_block_size(int frames);

	void route_notes(int peer_id, Object *synth);
	void set_clock(double offset, double output_latency);
	void set_steady_timing(bool on) { steady = on; }
	void send_event(int type, int a, float value, double at);
	static PackedByteArray pack_event(int sender, int type, int a, float value, double t, double at);
	int get_block_size() const { return block_size; }
};

} // namespace godot
