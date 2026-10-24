#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <bcrypt.h>

int main(void) {
    char *text = malloc(64);
    unsigned char random[8];
    WSADATA data;
    SOCKET handle;
    long status, started;
    if (!text) return 1;
    status = (long)BCryptGenRandom(NULL, random, sizeof random, BCRYPT_USE_SYSTEM_PREFERRED_RNG);
    started = WSAStartup(MAKEWORD(2, 2), &data);
    handle = socket(AF_INET, SOCK_STREAM, 0);
    if (handle != INVALID_SOCKET) closesocket(handle);
    snprintf(text, 64, "ok status=%ld started=%ld", status, started);
    printf("%s\n", text);
    free(text);
    WSACleanup();
    return 0;
}
