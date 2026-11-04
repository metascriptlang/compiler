#include <string.h>
#include "native.h"

static int counted = 0;

int nativeAdd(int a, int b) { return a + b; }
double nativeScale(double x, int k) { return x * k; }
float nativeHalf(float x) { return x / 2.0f; }
int64_t nativeWide(int64_t x) { return x * 3; }
unsigned char nativeByte(unsigned int x) { return (unsigned char)x; }
int nativeLen(const char *s) { return (int)strlen(s); }
void nativeCount(void) { counted += 1; }
int nativeCounted(void) { return counted; }
