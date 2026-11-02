#include <limits.h>
#include <stdio.h>
#include <stdlib.h>

/* Every checked operation is in range and in bounds when run with no argument (argc is 1), so a sanitized build prints
   the marker and exits 0. */
int main(int argc, char **argv) {
    (void)argv;
    volatile int edge = INT_MAX - 1;
    volatile int *block = malloc(4 * sizeof(int));
    if (!block) return 1;
    block[argc + 1] = edge + argc;
    printf("sanitizer clean %s\n", block[2] == INT_MAX ? "ok" : "wrong");
    free((void *)block);
    return 0;
}
