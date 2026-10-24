#include <float.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

static int sum(int count, ...) {
    va_list args;
    va_start(args, count);
    int total = 0;
    for (int i = 0; i < count; i++) total += va_arg(args, int);
    va_end(args);
    return total;
}

int main(void) {
    int *p = malloc(4 * sizeof(int));
    wchar_t wide = L'x';
    atomic_int counter = 0;
    for (int i = 0; i < 4; i++) p[i] = i * i;
    atomic_fetch_add(&counter, sum(4, p[0], p[1], p[2], p[3]));
    printf("ok sum=%d sqrt=%.3f wide=%d eps=%d\n", atomic_load(&counter), sqrt(2.0), (int)wide,
           DBL_EPSILON < 1e-10);
    free(p);
    return 0;
}
