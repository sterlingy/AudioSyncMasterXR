#include "jam_stem_recorder.h"
#include "jam_synth.h"
#ifdef JAM_HAVE_AOO
#include "net/jam_audio_link.h"
#endif
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <algorithm>
#include <cmath>

using namespace godot;

namespace {
constexpr double SAFETY = 1.0; // seconds kept open for late blocks before writing

std::string safe_name(const std::string &s) {
	std::string out;
	for (char c : s) out += (isalnum((unsigned char)c) || c == '-' || c == '_') ? c : '_';
	return out.empty() ? std::string("player") : out;
}

void put32(FILE *f, uint32_t v) { fwrite(&v, 4, 1, f); }
void put16(FILE *f, uint16_t v) { fwrite(&v, 2, 1, f); }
} // namespace

JamStemRecorder::~JamStemRecorder() {
	if (active) stop();
}

void JamStemRecorder::write_header(FILE *f, int rate, int64_t frames) {
	// RIFF / WAVE, IEEE float, stereo.
	const uint32_t data = (uint32_t)std::min<int64_t>(frames * 8, 0xFFFFFFF0LL);
	fseek(f, 0, SEEK_SET);
	fwrite("RIFF", 1, 4, f);
	put32(f, 36 + data);
	fwrite("WAVEfmt ", 1, 8, f);
	put32(f, 16);
	put16(f, 3); // IEEE float
	put16(f, 2);
	put32(f, (uint32_t)rate);
	put32(f, (uint32_t)rate * 8);
	put16(f, 8);
	put16(f, 32);
	fwrite("data", 1, 4, f);
	put32(f, data);
}

Error JamStemRecorder::start(const String &p_dir, double p_t_start, int p_rate) {
	if (active) stop();
	String abs = ProjectSettings::get_singleton()->globalize_path(p_dir);
	dir = std::string(abs.utf8().get_data());
	if (!dir.empty() && dir.back() != '/' && dir.back() != '\\') dir += "/";
	t_start = p_t_start;
	rate = std::max(8000, p_rate);
	window = rate * 8;
	flushed = 0;
	latest = 0;
	writers.clear();
	sources.clear();
	writer(""); // the mixdown always exists
	if (!writers[""].file) return ERR_CANT_CREATE;
	active = true;
	return OK;
}

JamStemRecorder::Writer &JamStemRecorder::writer(const std::string &player) {
	auto it = writers.find(player);
	if (it != writers.end()) return it->second;
	Writer &w = writers[player];
	w.path = dir + (player.empty() ? std::string("mixdown") : "stem_" + safe_name(player)) + ".wav";
	w.file = fopen(w.path.c_str(), "wb");
	w.ring.assign((size_t)window * 2, 0.0f);
	if (w.file) {
		write_header(w.file, rate, 0);
		// A player who starts late still lines up: silence up to now.
		std::vector<float> zeros(4096 * 2, 0.0f);
		for (int64_t done = 0; done < flushed;) {
			const int64_t n = std::min<int64_t>(4096, flushed - done);
			fwrite(zeros.data(), sizeof(float), (size_t)n * 2, w.file);
			done += n;
		}
		w.frames = flushed;
	} else {
		UtilityFunctions::push_error("JamStemRecorder: can't write ", String::utf8(w.path.c_str()));
	}
	return w;
}

void JamStemRecorder::add_synth(const String &player, Object *obj, double shift) {
	JamSynth *s = Object::cast_to<JamSynth>(obj);
	if (!s || !active) return;
	auto core = s->get_core();
	core->set_recording(true);
	Source src;
	src.player = std::string(player.utf8().get_data());
	src.shift = shift;
	src.tap = core->get_tap();
	src.keep = core;
	std::weak_ptr<jam::SynthCore> weak = core;
	src.stop = [weak] {
		if (auto k = weak.lock()) k->set_recording(false);
	};
	sources.push_back(std::move(src));
}

#ifdef JAM_HAVE_AOO
void JamStemRecorder::add_peer_voice(const String &player, Object *obj, int peer_id, double shift) {
	JamAudioLink *link = Object::cast_to<JamAudioLink>(obj);
	if (!link || !active) return;
	auto p = link->record_peer(peer_id, true);
	if (!p) return;
	Source src;
	src.player = std::string(player.utf8().get_data());
	src.shift = shift;
	src.tap = p->tap;
	src.keep = p;
	std::weak_ptr<JamPeerAudio> weak = p;
	src.stop = [weak] {
		if (auto k = weak.lock()) k->tap_on = false;
	};
	sources.push_back(std::move(src));
}

void JamStemRecorder::add_input(const String &player, Object *obj, double shift) {
	JamAudioLink *link = Object::cast_to<JamAudioLink>(obj);
	if (!link || !active) return;
	Ref<JamAudioLink> ref(link);
	Source src;
	src.player = std::string(player.utf8().get_data());
	src.shift = shift;
	src.tap = link->record_input(true);
	// Keep the link alive while we read its tap.
	auto holder = std::make_shared<Ref<JamAudioLink>>(ref);
	src.keep = holder;
	src.stop = [holder] { (*holder)->record_input(false); };
	sources.push_back(std::move(src));
}
#endif

void JamStemRecorder::add_block(Writer &w, int64_t index, const float *l, const float *r, int n) {
	w.used = true;
	for (int i = 0; i < n; i++) {
		const int64_t j = index + i;
		if (j < flushed) continue; // too late: already written
		const size_t k = (size_t)(j % window) * 2;
		w.ring[k] += l[i];
		w.ring[k + 1] += r[i];
	}
}

void JamStemRecorder::flush_to(int64_t upto) {
	if (upto <= flushed) return;
	for (auto &kv : writers) {
		Writer &w = kv.second;
		for (int64_t j = flushed; j < upto; j++) {
			const size_t k = (size_t)(j % window) * 2;
			if (w.file) fwrite(&w.ring[k], sizeof(float), 2, w.file);
			w.ring[k] = w.ring[k + 1] = 0.0f;
		}
		w.frames = upto;
	}
	flushed = upto;
}

void JamStemRecorder::pump() {
	if (!active) return;
	jam::TapBlock b;
	std::vector<float> rl, rr;
	for (Source &src : sources) {
		if (!src.tap) continue;
		Writer &w = writer(src.player);
		Writer &mix = writers[""];
		while (src.tap->read(b)) {
			const double t = b.time + src.shift - t_start;
			int64_t index = (int64_t)std::llround(t * rate);
			const float *l = b.l, *r = b.r;
			int n = b.frames;
			if (b.rate != rate) {
				// Linear resampling of the block onto our rate.
				n = (int)std::lround((double)b.frames * rate / b.rate);
				rl.resize(n);
				rr.resize(n);
				for (int i = 0; i < n; i++) {
					const double x = (double)i * b.rate / rate;
					const int k = std::min((int)x, b.frames - 1), k1 = std::min(k + 1, b.frames - 1);
					const float f = (float)(x - k);
					rl[i] = b.l[k] + (b.l[k1] - b.l[k]) * f;
					rr[i] = b.r[k] + (b.r[k1] - b.r[k]) * f;
				}
				l = rl.data();
				r = rr.data();
			}
			if (index + n <= 0) continue; // before the recording started
			if (index + n - flushed > window) flush_to(index + n - window); // far ahead: make room
			add_block(w, index, l, r, n);
			add_block(mix, index, l, r, n);
			latest = std::max(latest, index + n);
		}
	}
	flush_to(latest - (int64_t)(SAFETY * rate));
}

PackedStringArray JamStemRecorder::stop() {
	PackedStringArray files;
	if (!active) return files;
	pump();
	for (Source &src : sources)
		if (src.stop) src.stop();
	flush_to(latest);
	for (auto &kv : writers) {
		Writer &w = kv.second;
		if (!w.file) continue;
		write_header(w.file, rate, w.frames);
		fclose(w.file);
		w.file = nullptr;
		files.push_back(String::utf8(w.path.c_str()));
	}
	sources.clear();
	writers.clear();
	active = false;
	return files;
}

int JamStemRecorder::get_dropped() const {
	int d = 0;
	for (const Source &s : sources)
		if (s.tap) d += s.tap->dropped.load();
	return d;
}

void JamStemRecorder::_bind_methods() {
	ClassDB::bind_method(D_METHOD("start", "dir", "t_start", "rate"), &JamStemRecorder::start);
	ClassDB::bind_method(D_METHOD("add_synth", "player", "synth", "shift"), &JamStemRecorder::add_synth);
#ifdef JAM_HAVE_AOO
	ClassDB::bind_method(D_METHOD("add_peer_voice", "player", "link", "peer_id", "shift"), &JamStemRecorder::add_peer_voice);
	ClassDB::bind_method(D_METHOD("add_input", "player", "link", "shift"), &JamStemRecorder::add_input);
#endif
	ClassDB::bind_method(D_METHOD("pump"), &JamStemRecorder::pump);
	ClassDB::bind_method(D_METHOD("stop"), &JamStemRecorder::stop);
	ClassDB::bind_method(D_METHOD("is_active"), &JamStemRecorder::is_active);
	ClassDB::bind_method(D_METHOD("get_length"), &JamStemRecorder::get_length);
	ClassDB::bind_method(D_METHOD("get_dropped"), &JamStemRecorder::get_dropped);
}
