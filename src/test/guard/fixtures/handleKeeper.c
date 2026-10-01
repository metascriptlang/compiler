#include <stddef.h>

static void* msTestSlot = NULL;

void msTestKeep(void* p) { msTestSlot = p; }

void* msTestKept(void) { return msTestSlot; }
