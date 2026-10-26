#include "runtime/drc.h"
#include "orcArrayCellTrace.h"

int32_t msTestTracePushes(void* obj) {
	const msTypeInfo* type = msHeader(obj)->type;
	msGcEnv env = {0};
	msCellSeqInit(&env.traceStack);
	type->traceFn(obj, &env);
	int32_t pushed = env.traceStack.len;
	msCellSeqFree(&env.traceStack);
	return pushed;
}

void msTestCollectNow(void) {
	msOrcCollect();
}
