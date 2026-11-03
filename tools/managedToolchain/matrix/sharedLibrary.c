#if defined(_WIN32)
#define MATRIX_EXPORT __declspec(dllexport)
#else
#define MATRIX_EXPORT __attribute__((visibility("default")))
#endif

MATRIX_EXPORT int matrixLibraryValue(void) { return 42; }
