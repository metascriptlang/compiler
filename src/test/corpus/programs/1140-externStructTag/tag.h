#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <dirent.h>
#include <unistd.h>

struct Corpus1140Rec { int64_t head; int32_t skipped; double ratio; int32_t tailVal; uint8_t Flag; };
static inline void corpus1140RecFill(struct Corpus1140Rec* r, int32_t k) { r->head = k * 100; r->skipped = -1; r->ratio = k / 4.0; r->tailVal = k + 7; r->Flag = (uint8_t)k; }
static inline int64_t corpus1140RecHead(const struct Corpus1140Rec* r) { return r->head; }
static inline int64_t corpus1140RecSize(void) { return (int64_t)sizeof(struct Corpus1140Rec); }

static char corpus1140Dir[260];
static inline const char* corpus1140MakeDir(void) {
#ifdef _WIN32
	const char* base = getenv("TEMP");
#else
	const char* base = "/tmp";
#endif
	snprintf(corpus1140Dir, sizeof corpus1140Dir, "%s/corpus1140-%d", base, (int)getpid());
#ifdef _WIN32
	mkdir(corpus1140Dir);
#else
	mkdir(corpus1140Dir, 0700);
#endif
	char path[300];
	snprintf(path, sizeof path, "%s/f.txt", corpus1140Dir);
	FILE* f = fopen(path, "wb");
	if (f) { fputs("hello\n", f); fclose(f); }
	return corpus1140Dir;
}
static inline void corpus1140RemoveDir(void) {
	char path[300];
	snprintf(path, sizeof path, "%s/f.txt", corpus1140Dir);
	unlink(path);
	rmdir(corpus1140Dir);
}

typedef struct Corpus1140Pair { int32_t a; int64_t b; int32_t c; } Corpus1140Pair;
static inline int64_t corpus1140PairSize(void) { return (int64_t)sizeof(Corpus1140Pair); }
