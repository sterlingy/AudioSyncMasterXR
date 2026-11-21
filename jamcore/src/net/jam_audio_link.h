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
	std::atomic<bool> sending{false};
	std::atomic<float> input_peak{0.0f};
	std::atomic<float> input_gain{1.0f};
	int source_rate = 0;
	float latency_ms = 15.0f;
	String codec = "pcm16";
	int opus_bitrate = 128000;
	int block_size = 128;
	double capture_period_ms = 0.0;

	void net_loop();
	void setup_source(int sample_rate);
	void apply_format();
	void feed(const float *mono, int frames, int sample_rate);
	static AooInt32 AOO_CALL send_fn(void *user, const AooByte *data, AooInt32 size, const void *address, AooAddrSize addrlen, AooFlag flags);
	static void AOO_CALL source_event(void *user, const AooEvent *e, AooThreadLevel level);
	static void AOO_CALL sink_event(void *user, const AooEvent *e, AooThreadLevel level);

protected:
	static void _bind_methods();

public:
	JamAudioLink();
	~JamAudioLink();

	Error start(int port, int p_my_id);
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
	Error start_capture(int device, int channel);
	void stop_capture();
	bool is_capturing() const { return capture.running(); }
	String get_capture_error() const { return String(capture.error().c_str()); }
	double get_capture_period_ms() const { return capture_period_ms; }
	void push_input(const PackedVector2Array &frames, int sample_rate);

	void set_sending(bool on);
	bool is_sending() const { return sending.load(); }
	void set_input_gain(float g) { input_gain = g; }
	float take_input_peak() { return input_peak.exchange(0.0f); }
	void set_latency_ms(float ms);
	float get_latency_ms() const { return latency_ms; }
	void set_codec(const String &name, int bitrate);
	String get_codec() const { return codec; }
	void set_block_size(int frames);
	int get_block_size() const { return block_size; }
};

} // namespace godot
