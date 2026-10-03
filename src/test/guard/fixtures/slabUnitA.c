#include "runtime/drc.h"
#include "slabUnits.h"

void msTestSlabGive(void* p);

bool msTestSlabReusedAcrossUnits(void) {
	void* given = msSlabAllocRaw(48);
	msTestSlabGive(given);
	void* taken = msSlabAllocRaw(48);
	msSlabFree(taken, 48);
	return taken == given;
}
