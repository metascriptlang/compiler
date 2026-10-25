#pragma once
#include "un.h"

size_t corpus1143Size(int which) {
	switch (which) {
	case 0: return sizeof(Corpus1143Top);
	case 1: return sizeof(Corpus1143Style);
	case 2: return sizeof(Corpus1143PadUnion);
	case 3: return sizeof(Corpus1143Mixed);
	case 4: return sizeof(Corpus1143Round);
	case 5: return sizeof(Corpus1143Nest);
	case 6: return sizeof(Corpus1143Holder);
	default: return 0;
	}
}

int64_t corpus1143Fg(const Corpus1143Style* s) {
	return s->size == sizeof(Corpus1143Style) ? s->fg.value.rgb.r + s->fg.value.rgb.g + s->fg.value.rgb.b : -1;
}
