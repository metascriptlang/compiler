#include <unistd.h>
#include <stdint.h>

static int corpusWaitPipes[8][2];

static inline int32_t corpusWaitPipeOpen(int32_t i) { return pipe(corpusWaitPipes[i]); }
static inline int32_t corpusWaitPipeReadFd(int32_t i) { return corpusWaitPipes[i][0]; }
static inline int32_t corpusWaitPipeWrite(int32_t i, int32_t b) { uint8_t c = (uint8_t)b; return (int32_t)write(corpusWaitPipes[i][1], &c, 1); }
static inline int32_t corpusWaitReadByte(int32_t fd) { uint8_t c; ssize_t n = read(fd, &c, 1); return n == 1 ? c : -1; }
static inline void corpusWaitSleepMs(int32_t ms) { usleep((useconds_t)ms * 1000); }
