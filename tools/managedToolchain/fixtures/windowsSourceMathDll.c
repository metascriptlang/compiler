#include <math.h>
#include <windows.h>

/* Nonconstant like windowsSourceMath.c: the argument decides every input. Returns 1 when pow, fmod, nan and nanl
   all behave, so a caller that loads the DLL needs no output to check it. */
__declspec(dllexport) int mathProbe(int argument) {
    volatile double two = argument + 2.0;
    volatile char tag = argument > 100 ? 'x' : '\0';
    char tags[2] = {tag, '\0'};
    double power = pow(two, 10.0);
    double remainder = fmod(two * 5.0, 4.0);
    double quiet = nan(tags);
    long double quietLong = nanl(tags);
    return power == 1024.0 && remainder == 2.0 && isnan(quiet) && isnan(quietLong) ? 1 : 0;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved) {
    (void)instance; (void)reason; (void)reserved;
    return TRUE;
}
