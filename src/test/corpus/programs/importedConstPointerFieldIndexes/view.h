#include <stdint.h>
#include <stddef.h>

typedef struct { const uint8_t* ptr; size_t len; } ByteView;
typedef struct { const int32_t* ip; size_t len; } IntView;

static inline void fillBytes(ByteView* v) { static const uint8_t d[3] = { 7, 8, 9 }; v->ptr = d; v->len = 3; }
static inline void fillInts(IntView* v) { static const int32_t d[3] = { -70000, 80000, 90000 }; v->ip = d; v->len = 3; }
