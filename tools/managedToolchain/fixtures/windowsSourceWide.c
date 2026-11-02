#include <math.h>
#include <stdio.h>
#include <wchar.h>

/* The Unicode startup object (crt2u.o) calls wmain; the math is nonconstant as in windowsSourceMath.c. */
int wmain(int argc, wchar_t **argv) {
    volatile double two = argc + 1.0;
    volatile char tag = argc > 100 ? 'x' : '\0';
    char tags[2] = {tag, '\0'};
    printf("wide argc=%d first=%d pow=%d nan=%d\n", argc, argv[0][0] != 0 ? 1 : 0, (int)pow(two, 10.0),
           isnan(nan(tags)) ? 1 : 0);
    return 0;
}
