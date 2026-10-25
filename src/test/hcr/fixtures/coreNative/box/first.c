#include <stdint.h>
#include "shared.h"

#define HCR_NATIVE_TEXT2(x) #x
#define HCR_NATIVE_TEXT(x) HCR_NATIVE_TEXT2(x)

__attribute__((used)) static const char hcrNativeRev[] = HCR_NATIVE_TEXT(HCR_NATIVE_REV);

int32_t hcrNativeFirst(void) {
	return hcrNativeRev[0] != 0 ? 1 : 0;
}
