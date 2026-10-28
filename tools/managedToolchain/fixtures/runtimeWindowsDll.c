#include <stdio.h>
#include <stdlib.h>
#include <winsock2.h>
#include <windows.h>
#include <bcrypt.h>

__declspec(dllexport) int addNumbers(int a, int b) {
    char *text = malloc(8);
    unsigned char random[8];
    WSADATA data;
    free(text);
    BCryptGenRandom(NULL, random, sizeof random, BCRYPT_USE_SYSTEM_PREFERRED_RNG);
    if (WSAStartup(MAKEWORD(2, 2), &data) == 0) WSACleanup();
    printf("add\n");
    return a + b;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved) {
    (void)instance; (void)reason; (void)reserved;
    return TRUE;
}
