#include "runtime/drc.h"
#include "runtime/core/string.h"

void rcPinOwnerInc(void* p) { msIncRef(p); }
bool rcPinOwnerDec(void* p) { return msDecRefIsLast(p); }
void rcPinOwnerOrcInc(void* p) { msOrcIncRef(p); }
bool rcPinOwnerOrcDec(void* p) { return msOrcDecRefIsLast(p); }
void rcPinOwnerMark(void* p) { msMarkMaybeCycle(p); }
void rcPinShareInc(void* p) { msAtomicIncRef(p); }
bool rcPinShareDec(void* p) { return msAtomicDecRefIsLast(p); }

bool rcPinIsAscii(msString s) { return msStringIsAscii(s); }
