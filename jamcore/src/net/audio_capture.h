// Native microphone / audio-interface capture. Windows: WASAPI shared mode,
// event driven, at the device's smallest engine period (IAudioClient3) when
// the driver allows it. Other platforms: not yet (Android AAudio/Oboe comes
// with the headset milestone); Godot's own capture is the fallback there.
#pragma once
#include <atomic>
#include <functional>
#include <string>
#include <thread>
#include <vector>

namespace jam {

// Called on the capture thread with mono float frames at the device rate.
using CaptureCallback = std::function<void(const float *mono, int frames, int sample_rate)>;

class AudioCapture {
public:
	static bool supported();
	static std::vector<std::string> list_devices(); // index 0..n-1; -1 = system default

	~AudioCapture() { stop(); }
	// channel: -1 = mix all input channels, otherwise that channel only.
	bool start(int device, int channel, CaptureCallback cb);
	void stop();
	bool running() const { return active.load(); }
	int sample_rate() const { return rate.load(); }
	double period_ms() const { return period.load(); }
	std::string error() const { return err; }

private:
	void run(int device, int channel);
	CaptureCallback callback;
	std::thread thread;
	std::atomic<bool> quit{false};
	std::atomic<bool> active{false};
	std::atomic<bool> started{false};
	std::atomic<int> rate{0};
	std::atomic<double> period{0.0};
	std::string err;
};

} // namespace jam
