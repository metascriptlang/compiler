#include <stdio.h>
#include <stdlib.h>
#include <windows.h>

typedef int (*Probe)(int);

/* proveWindowsSanitizerRuntime.py reads the windowsSanitizerHost: prefix of stderr as the host's own failure. */
__attribute__((no_sanitize("function")))
int wmain(int argc, wchar_t **argv) {
    if (argc != 5) {
        fprintf(stderr, "windowsSanitizerHost: usage: DLL EXPORT STEP EXPECTED\n");
        return 2;
    }
    HMODULE module = LoadLibraryW(argv[1]);
    if (!module) {
        fprintf(stderr, "windowsSanitizerHost: LoadLibraryW(%ls) failed with error %lu\n", argv[1], GetLastError());
        return 2;
    }
    char name[128];
    if (!WideCharToMultiByte(CP_ACP, 0, argv[2], -1, name, sizeof name, NULL, NULL)) {
        fprintf(stderr, "windowsSanitizerHost: export name %ls does not convert\n", argv[2]);
        return 2;
    }
    Probe probe = (Probe)(void *)GetProcAddress(module, name);
    if (!probe) {
        fprintf(stderr, "windowsSanitizerHost: GetProcAddress(%s) failed with error %lu\n", name, GetLastError());
        return 2;
    }
    int step = (int)wcstol(argv[3], NULL, 10), expected = (int)wcstol(argv[4], NULL, 10);
    int result = probe(step);
    if (result != expected) {
        fprintf(stderr, "windowsSanitizerHost: %s(%d) returned %d, expected %d\n", name, step, result, expected);
        return 3;
    }
    if (!FreeLibrary(module)) {
        fprintf(stderr, "windowsSanitizerHost: FreeLibrary failed with error %lu\n", GetLastError());
        return 4;
    }
    printf("sanitizer host ok\n");
    return 0;
}
