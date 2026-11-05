#include "runtime/core/system.h"
#include "bareHeapChecks.h"

void msBareHeapOtherUnitFree(void* p) {
	free(p);
}
