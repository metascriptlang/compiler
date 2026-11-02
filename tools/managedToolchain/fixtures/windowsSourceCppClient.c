#include <stdio.h>

int windowsSourceCppArchiveSum(int count);

int main(int argc, char **argv) {
    (void)argv;
    printf("archive sum=%d\n", windowsSourceCppArchiveSum(3 + argc));
    return 0;
}
