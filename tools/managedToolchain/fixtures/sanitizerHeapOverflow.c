#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    volatile int *p = malloc(4 * sizeof(int));
    if (!p) return 1;
    p[argc + 3] = 1;
    printf("unreachable\n");
    free((void *)p);
    return 0;
}
