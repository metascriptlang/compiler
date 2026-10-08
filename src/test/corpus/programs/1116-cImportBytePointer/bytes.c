#include "bytes.h"
int bytesSum(const unsigned char *d, int n) { int t = 0; for (int i = 0; i < n; i++) t += d[i]; return t; }
int bytesSum8(const uint8_t *d, int n) { int t = 0; for (int i = 0; i < n; i++) t += d[i]; return t; }
int textLen(const char *s) { int n = 0; while (s[n]) n++; return n; }
