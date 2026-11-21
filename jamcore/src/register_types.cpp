#include "jam_synth.h"
#ifdef JAM_HAVE_AOO
#include "net/jam_audio_link.h"
#endif
#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_jamcore(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) return;
	GDREGISTER_CLASS(JamSynthPlayback);
	GDREGISTER_CLASS(JamSynth);
#ifdef JAM_HAVE_AOO
	GDREGISTER_CLASS(JamNetStreamPlayback);
	GDREGISTER_CLASS(JamNetStream);
	GDREGISTER_CLASS(JamAudioLink);
#endif
}

void uninitialize_jamcore(ModuleInitializationLevel p_level) {}

extern "C" GDExtensionBool GDE_EXPORT jamcore_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address, const GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
	init_obj.register_initializer(initialize_jamcore);
	init_obj.register_terminator(uninitialize_jamcore);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_obj.init();
}
