#pragma once
#include "sz.h"

size_t corpus1141VersionedSize(void) { return sizeof(Corpus1141Versioned); }
size_t corpus1141BigSize(void) { return sizeof(Corpus1141Big); }
size_t corpus1141USize(void) { return sizeof(Corpus1141U); }
int64_t corpus1141Accept(const Corpus1141Versioned* v) { return v->size == sizeof(Corpus1141Versioned) ? v->a : -1; }
int64_t corpus1141BigSum(Corpus1141Big b) { return (int64_t)b.v.size + b.v.a + b.w + b.x + b.y + b.z + b.tag; }
