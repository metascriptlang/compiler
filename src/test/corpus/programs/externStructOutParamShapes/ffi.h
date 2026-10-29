#include <stdint.h>

typedef struct { int32_t x; int32_t y; } Corpus1181Point;
typedef struct { Corpus1181Point from; Corpus1181Point to; double weight; } Corpus1181Seg;

static inline Corpus1181Point corpus1181Make(int32_t x, int32_t y) { Corpus1181Point p = { x, y }; return p; }
static inline void corpus1181Span(Corpus1181Seg* s) { s->from.x = 1; s->from.y = 2; s->to.x = 30; s->to.y = 40; s->weight = 0.5; }
static inline void corpus1181Scale(Corpus1181Point* p, int32_t k) { p->x *= k; p->y *= k; }
