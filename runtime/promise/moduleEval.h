/*
 * import(): a module reached only through import() runs its body on first import,
 * on the loop thread. The dispatcher registers one record per such module and per
 * import() target; a target the program initialized at startup is registered evaluated.
 */
#ifndef MS_MODULE_EVAL_H
#define MS_MODULE_EVAL_H

#include <stdint.h>

enum { MS_MODULE_PENDING = 0, MS_MODULE_EVALUATING = 1, MS_MODULE_EVALUATED = 2 };

typedef struct msModuleRecord {
	const char* name;
	void (*init)(void);
	void (*deinit)(void);
	const int32_t* requested;
	int32_t requestedCount;
	int32_t status;
	int32_t dfsIndex;
	int32_t dfsAncestorIndex;
	void* error;
} msModuleRecord;

extern int32_t msModuleEvalDepth;

void msModuleTableRegister(msModuleRecord* records, int32_t count);
void* msModuleImport(msString name);
void msModuleDeinitLazy(void);

#endif /* MS_MODULE_EVAL_H */
