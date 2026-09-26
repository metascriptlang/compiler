#include <stdint.h>
#include <stdbool.h>

typedef enum { CORPUS890_IDLE = 1, CORPUS890_BUSY = 2 } Corpus890Mode;
typedef struct { int32_t base; int32_t step; } Corpus890Cfg;
typedef enum { CORPUS890_KEY_COLS = 1, CORPUS890_KEY_MODE = 2, CORPUS890_KEY_CFG = 3 } Corpus890Key;

static inline int corpus890FillI32(int32_t* p) { if (!p) return -1; *p = 5; return 0; }
static inline bool corpus890NextRow(uint16_t* outY) { if (!outY) return false; *outY += 1; return true; }
static inline int corpus890FillF64(double* p) { if (!p) return -1; *p = 2.5; return 0; }
static inline int corpus890FillBool(bool* p) { if (!p) return -1; *p = true; return 0; }
static inline int corpus890FillMode(Corpus890Mode* p) { if (!p) return -1; *p = CORPUS890_BUSY; return 0; }
static inline int corpus890ReadI32(const int32_t* p) { return p ? *p : -1; }
static inline int corpus890Get(Corpus890Key key, void* out) {
	if (!out) return -1;
	if (key == CORPUS890_KEY_COLS) { *(uint16_t*)out = 80; return 0; }
	if (key == CORPUS890_KEY_MODE) { *(Corpus890Mode*)out = CORPUS890_BUSY; return 0; }
	if (key == CORPUS890_KEY_CFG) { ((Corpus890Cfg*)out)->step = 9; return 0; }
	return 1;
}
