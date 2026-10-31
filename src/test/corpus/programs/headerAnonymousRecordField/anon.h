typedef struct CorpusAnonOuter {
	struct { int x; int y; } inner;
	union { int i; float f; } u;
	struct { struct { int a; } leaf[2]; } mid;
	union { long long tag; double weight; };
	int z;
} CorpusAnonOuter;

static inline CorpusAnonOuter corpusAnonMake(void) {
	CorpusAnonOuter o = {0};
	o.inner.x = 3; o.inner.y = 4; o.u.i = 5; o.mid.leaf[1].a = 6; o.tag = 8; o.z = 7;
	return o;
}

static inline int corpusAnonSum(CorpusAnonOuter *o) {
	return o->inner.x + o->u.i + o->mid.leaf[1].a + (int)o->tag + o->z;
}
