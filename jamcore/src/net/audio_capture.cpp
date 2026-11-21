#include "audio_capture.h"

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <avrt.h>
#include <propsys.h>
#endif

#include <chrono>
#include <cstring>

namespace jam {

#ifdef _WIN32

namespace {
const GUID kSubtypePcm = {0x00000001, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
const GUID kSubtypeFloat = {0x00000003, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};

// kFriendlyName (functiondiscoverykeys_devpkey.h)
const PROPERTYKEY kFriendlyName = {{0xa45c254e, 0xdf1c, 0x4efd, {0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0}}, 14};

template <class T>
void release(T *&p) {
	if (p) {
		p->Release();
		p = nullptr;
	}
}

std::string narrow(const wchar_t *w) {
	int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
	std::string s(n > 0 ? n - 1 : 0, '\0');
	if (n > 1) WideCharToMultiByte(CP_UTF8, 0, w, -1, s.data(), n, nullptr, nullptr);
	return s;
}

IMMDevice *get_device(IMMDeviceEnumerator *en, int index) {
	IMMDevice *dev = nullptr;
	if (index < 0) {
		en->GetDefaultAudioEndpoint(eCapture, eConsole, &dev);
		return dev;
	}
	IMMDeviceCollection *col = nullptr;
	if (SUCCEEDED(en->EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE, &col))) {
		col->Item((UINT)index, &dev);
		release(col);
	}
	return dev;
}
} // namespace

bool AudioCapture::supported() { return true; }

std::vector<std::string> AudioCapture::list_devices() {
	std::vector<std::string> out;
	HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
	IMMDeviceEnumerator *en = nullptr;
	IMMDeviceCollection *col = nullptr;
	if (SUCCEEDED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, __uuidof(IMMDeviceEnumerator), (void **)&en)) &&
			SUCCEEDED(en->EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE, &col))) {
		UINT n = 0;
		col->GetCount(&n);
		for (UINT i = 0; i < n; i++) {
			IMMDevice *dev = nullptr;
			IPropertyStore *props = nullptr;
			std::string name = "Input " + std::to_string(i + 1);
			if (SUCCEEDED(col->Item(i, &dev)) && SUCCEEDED(dev->OpenPropertyStore(STGM_READ, &props))) {
				PROPVARIANT v;
				PropVariantInit(&v);
				if (SUCCEEDED(props->GetValue(kFriendlyName, &v)) && v.vt == VT_LPWSTR) name = narrow(v.pwszVal);
				PropVariantClear(&v);
			}
			release(props);
			release(dev);
			out.push_back(name);
		}
	}
	release(col);
	release(en);
	if (SUCCEEDED(co)) CoUninitialize();
	return out;
}

bool AudioCapture::start(int device, int channel, CaptureCallback cb, bool exclusive) {
	stop();
	callback = std::move(cb);
	quit = false;
	started = false;
	err.clear();
	thread = std::thread([this, device, channel, exclusive] { run(device, channel, exclusive); });
	// Wait for the device to open (or fail).
	for (int i = 0; i < 300 && !started.load(); i++) std::this_thread::sleep_for(std::chrono::milliseconds(10));
	if (!active.load()) {
		stop();
		if (err.empty()) err = "the input device didn't start";
		return false;
	}
	return true;
}

void AudioCapture::stop() {
	quit = true;
	if (thread.joinable()) thread.join();
	active = false;
}

void AudioCapture::run(int device, int channel, bool exclusive) {
	HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
	IMMDeviceEnumerator *en = nullptr;
	IMMDevice *dev = nullptr;
	IAudioClient *client = nullptr;
	IAudioClient3 *client3 = nullptr;
	IAudioCaptureClient *cap = nullptr;
	WAVEFORMATEX *fmt = nullptr;
	WAVEFORMATEXTENSIBLE xfmt{};
	HANDLE event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
	HANDLE mmcss = nullptr;
	std::vector<float> mono;
	bool is_float = false;
	int bits = 16, nch = 1;

	auto fail = [&](const char *what) {
		err = what;
		started = true;
	};

	if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, __uuidof(IMMDeviceEnumerator), (void **)&en))) {
		fail("no audio device enumerator");
		goto done;
	}
	dev = get_device(en, device);
	if (!dev) {
		fail("input device not found");
		goto done;
	}
	if (FAILED(dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void **)&client)) || FAILED(client->GetMixFormat(&fmt))) {
		fail("couldn't open the input device");
		goto done;
	}
	nch = fmt->nChannels;
	bits = fmt->wBitsPerSample;
	is_float = fmt->wFormatTag == WAVE_FORMAT_IEEE_FLOAT ||
			(fmt->wFormatTag == WAVE_FORMAT_EXTENSIBLE && ((WAVEFORMATEXTENSIBLE *)fmt)->SubFormat.Data1 == WAVE_FORMAT_IEEE_FLOAT);
	excl = false;
	if (exclusive) {
		// Try common interface formats at 48 kHz, then at the device's own rate.
		struct Cand {
			WORD bits, valid;
			bool flt;
		} cands[] = {{32, 32, true}, {32, 24, false}, {24, 24, false}, {16, 16, false}};
		const DWORD rates[] = {48000, fmt->nSamplesPerSec};
		REFERENCE_TIME def_p = 0, min_p = 0;
		client->GetDevicePeriod(&def_p, &min_p);
		for (DWORD r : rates) {
			for (const Cand &c : cands) {
				WAVEFORMATEXTENSIBLE x{};
				x.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
				x.Format.nChannels = (WORD)nch;
				x.Format.nSamplesPerSec = r;
				x.Format.wBitsPerSample = c.bits;
				x.Format.nBlockAlign = (WORD)(nch * c.bits / 8);
				x.Format.nAvgBytesPerSec = r * x.Format.nBlockAlign;
				x.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
				x.Samples.wValidBitsPerSample = c.valid;
				x.dwChannelMask = fmt->wFormatTag == WAVE_FORMAT_EXTENSIBLE ? ((WAVEFORMATEXTENSIBLE *)fmt)->dwChannelMask : 0;
				x.SubFormat = c.flt ? kSubtypeFloat : kSubtypePcm;
				if (client->IsFormatSupported(AUDCLNT_SHAREMODE_EXCLUSIVE, &x.Format, nullptr) != S_OK) continue;
				REFERENCE_TIME p = min_p;
				HRESULT hr = client->Initialize(AUDCLNT_SHAREMODE_EXCLUSIVE, AUDCLNT_STREAMFLAGS_EVENTCALLBACK, p, p, &x.Format, nullptr);
				if (hr == AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED) {
					UINT32 frames = 0;
					client->GetBufferSize(&frames);
					release(client);
					dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void **)&client);
					p = (REFERENCE_TIME)(10000.0 * 1000.0 * frames / r + 0.5);
					hr = client->Initialize(AUDCLNT_SHAREMODE_EXCLUSIVE, AUDCLNT_STREAMFLAGS_EVENTCALLBACK, p, p, &x.Format, nullptr);
				}
				if (SUCCEEDED(hr)) {
					xfmt = x;
					excl = true;
					period = p / 10000.0;
					break;
				}
				// A failed Initialize leaves the client unusable: start over with a fresh one.
				release(client);
				dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void **)&client);
			}
			if (excl.load()) break;
		}
		if (excl.load()) {
			// Convert using the exclusive format from now on.
			CoTaskMemFree(fmt);
			fmt = (WAVEFORMATEX *)CoTaskMemAlloc(sizeof(WAVEFORMATEXTENSIBLE));
			memcpy(fmt, &xfmt, sizeof(WAVEFORMATEXTENSIBLE));
			bits = xfmt.Format.wBitsPerSample;
			is_float = xfmt.SubFormat == kSubtypeFloat;
		} else {
			err = "exclusive mode refused; using shared mode";
		}
	}
	if (!excl.load()) {
		bool ok = false;
		// Smallest shared-mode period the driver offers (often 2.7-5 ms instead of 10 ms).
		if (SUCCEEDED(client->QueryInterface(__uuidof(IAudioClient3), (void **)&client3))) {
			UINT32 def = 0, fund = 0, mn = 0, mx = 0;
			if (SUCCEEDED(client3->GetSharedModeEnginePeriod(fmt, &def, &fund, &mn, &mx)) &&
					SUCCEEDED(client3->InitializeSharedAudioStream(AUDCLNT_STREAMFLAGS_EVENTCALLBACK, mn, fmt, nullptr))) {
				ok = true;
				period = 1000.0 * mn / fmt->nSamplesPerSec;
			}
		}
		if (!ok) {
			REFERENCE_TIME def_period = 0, min_period = 0;
			client->GetDevicePeriod(&def_period, &min_period);
			if (FAILED(client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_EVENTCALLBACK, 0, 0, fmt, nullptr))) {
				fail("the input device refused the stream format");
				goto done;
			}
			period = def_period / 10000.0;
		}
	}
	if (FAILED(client->SetEventHandle(event)) || FAILED(client->GetService(__uuidof(IAudioCaptureClient), (void **)&cap))) {
		fail("couldn't start capturing");
		goto done;
	}
	rate = (int)fmt->nSamplesPerSec;
	{
		DWORD task = 0;
		mmcss = AvSetMmThreadCharacteristicsW(L"Pro Audio", &task);
	}
	if (FAILED(client->Start())) {
		fail("couldn't start the input device");
		goto done;
	}
	active = true;
	started = true;

	while (!quit.load()) {
		if (WaitForSingleObject(event, 100) != WAIT_OBJECT_0) continue;
		UINT32 avail = 0;
		while (SUCCEEDED(cap->GetNextPacketSize(&avail)) && avail > 0) {
			BYTE *data = nullptr;
			UINT32 frames = 0;
			DWORD flags = 0;
			if (FAILED(cap->GetBuffer(&data, &frames, &flags, nullptr, nullptr))) break;
			if (mono.size() < frames) mono.resize(frames); // grows once, to the period size
			const bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
			const int c0 = (channel >= 0 && channel < nch) ? channel : 0;
			const int cn = (channel >= 0 && channel < nch) ? 1 : nch;
			const float scale = 1.0f / cn;
			for (UINT32 i = 0; i < frames; i++) {
				float sum = 0.0f;
				if (!silent) {
					for (int c = c0; c < c0 + cn; c++) {
						const size_t k = (size_t)i * nch + c;
						if (is_float) {
							sum += ((const float *)data)[k];
						} else if (bits == 16) {
							sum += ((const int16_t *)data)[k] * (1.0f / 32768.0f);
						} else if (bits == 32) {
							sum += ((const int32_t *)data)[k] * (1.0f / 2147483648.0f);
						} else if (bits == 24) {
							const uint8_t *b = data + k * 3;
							int32_t v = (int32_t)((uint32_t)b[0] << 8 | (uint32_t)b[1] << 16 | (uint32_t)b[2] << 24);
							sum += v * (1.0f / 2147483648.0f);
						}
					}
				}
				mono[i] = sum * scale;
			}
			cap->ReleaseBuffer(frames);
			if (callback) callback(mono.data(), (int)frames, rate.load());
		}
	}
	client->Stop();

done:
	active = false;
	if (mmcss) AvRevertMmThreadCharacteristics(mmcss);
	if (fmt) CoTaskMemFree(fmt);
	release(cap);
	release(client3);
	release(client);
	release(dev);
	release(en);
	CloseHandle(event);
	if (SUCCEEDED(co)) CoUninitialize();
}

#else // not Windows

bool AudioCapture::supported() { return false; }
std::vector<std::string> AudioCapture::list_devices() { return {}; }
bool AudioCapture::start(int, int, CaptureCallback, bool) {
	err = "native capture isn't available on this platform yet";
	return false;
}
void AudioCapture::stop() {}
void AudioCapture::run(int, int, bool) {}

#endif

} // namespace jam
