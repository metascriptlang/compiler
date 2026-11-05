#include <stdint.h>

__attribute__((export_name("checkedMultiply")))
int32_t msBareWasmMulOverflow(int64_t a, int64_t b, int64_t expected,
                            int32_t expectedOverflow) {
    int64_t result;
    int32_t overflow = __builtin_mul_overflow(a, b, &result);
    if (overflow != expectedOverflow) return 1;
    if (!overflow && result != expected) return 2;
    return 0;
}
