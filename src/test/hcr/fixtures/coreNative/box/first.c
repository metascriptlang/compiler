#include <stdint.h>
#include "shared.h"

int32_t hcrNativeFirst(void) {
	return HCR_NATIVE_REV != 0 ? 1 : 0;
}
