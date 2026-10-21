#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include "pump.h"

extern bool msRunOnce(int timeoutMs);

int64_t msTestLengthAfterPump(const char* s) {
	for (int i = 0; i < 3; i++) msRunOnce(1);
	return (int64_t)strlen(s);
}
