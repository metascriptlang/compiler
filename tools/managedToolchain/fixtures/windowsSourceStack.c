#include <stdio.h>

#define KEEP_IN_MEMORY(pointer) __asm__ __volatile__("" : : "r"(pointer) : "memory")

__attribute__((noinline)) static int checksum(int length) {
    char bytes[16];
    int total = 0;
    for (int i = 0; i < length; i++) bytes[i] = (char)(i + 1);
    KEEP_IN_MEMORY(bytes);
    for (int i = 0; i < length; i++) total += bytes[i];
    return total;
}

int main(int argc, char **argv) {
    (void)argv;
    printf("stack sum=%d\n", checksum((argc & 7) + 8));
    return 0;
}
