#include "instrument.h"

namespace jam {

Instrument *make_undertow();
Instrument *make_comet();
Instrument *make_lumen();
Instrument *make_pulsar();
Instrument *make_driftwood();
Instrument *make_tangle();

struct Entry {
	const char *name;
	Instrument *(*make)();
};

static const Entry entries[] = {
	{ "Pulsar", make_pulsar },
	{ "Undertow", make_undertow },
	{ "Comet", make_comet },
	{ "Lumen", make_lumen },
	{ "Driftwood", make_driftwood },
	{ "Tangle", make_tangle },
};

Instrument *create_instrument(const std::string &type) {
	for (const Entry &e : entries)
		if (type == e.name) return e.make();
	return nullptr;
}

std::vector<std::string> instrument_types() {
	std::vector<std::string> out;
	for (const Entry &e : entries) out.push_back(e.name);
	return out;
}

} // namespace jam
