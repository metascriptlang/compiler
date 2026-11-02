#include <stdio.h>

__declspec(dllexport) __attribute__((noinline)) int stackSum(int length) {
    if (length < 0 || length > 16) return -1;
    char bytes[16];
    int total = 0;
    for (int i = 0; i < length; i++) bytes[i] = (char)(i + 1);
    __asm__ __volatile__("" : : "r"(bytes) : "memory");
    for (int i = 0; i < length; i++) total += bytes[i];
    printf("stack dll sum=%d\n", total);
    return total;
}
