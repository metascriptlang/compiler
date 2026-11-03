#include <limits.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    volatile int edge = INT_MAX - 1;
    volatile int *p = malloc(4 * sizeof(int));
    if (!p) return 1;
    p[argc + 2] = edge + argc;
    printf("%s\n", p[3] == INT_MAX ? "ok" : "wrong");
    free((void *)p);
    return 0;
}
