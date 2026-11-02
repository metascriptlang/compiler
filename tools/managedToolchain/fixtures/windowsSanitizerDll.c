#include <limits.h>
#include <stdlib.h>
#include <windows.h>

/* step 0 is in range and in bounds and returns 0; step 1 overflows a signed addition (UBSan); step 2 stores one int past
   the end of a four-int heap block (ASan). */
__declspec(dllexport) int sanitizerCProbe(int step) {
    volatile int big = INT_MAX;
    volatile int *block = malloc(4 * sizeof(int));
    if (!block) return -1;
    block[step == 2 ? 4 : 3] = 1;
    int result = step == 1 ? big + step : 0;
    free((void *)block);
    return result;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved) {
    (void)instance; (void)reason; (void)reserved;
    return TRUE;
}
