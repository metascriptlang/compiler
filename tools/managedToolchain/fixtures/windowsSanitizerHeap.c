#include <stdio.h>
#include <stdlib.h>

/* With no argument (argc is 1) the store is one int past the end of a four-int heap block: an ASan build reports a
   heap-buffer-overflow at this file and line and exits nonzero before the marker. */
int main(int argc, char **argv) {
    (void)argv;
    volatile int *block = malloc(4 * sizeof(int));
    if (!block) return 1;
    block[argc + 3] = 1;
    printf("sanitizer heap unreachable\n");
    free((void *)block);
    return 0;
}
