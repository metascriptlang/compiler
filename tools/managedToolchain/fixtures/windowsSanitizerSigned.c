#include <limits.h>
#include <stdio.h>

/* With no argument (argc is 1) the signed addition overflows: a UBSan build reports it at this file and line, and one
   built with -fno-sanitize-recover=undefined exits nonzero before the marker. */
int main(int argc, char **argv) {
    (void)argv;
    volatile int big = INT_MAX;
    int sum = big + argc;
    printf("sanitizer signed unreachable %d\n", sum);
    return 0;
}
