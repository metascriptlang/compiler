/*
 * import(): a module reached only through import() runs its body on first import,
 * on the loop thread. The dispatcher registers one record per such module and per
 * import() target; a target the program initialized at startup is registered evaluated.
 * A body with a top-level await runs as an async routine: the modules that import it
 * run theirs once it settles, and every import() of them waits for the same evaluation.
 */
#ifndef MS_MODULE_EVAL_H
#define MS_MODULE_EVAL_H

#include <stdint.h>

enum { MS_MODULE_PENDING = 0, MS_MODULE_EVALUATING = 1, MS_MODULE_EVALUATING_ASYNC = 2, MS_MODULE_EVALUATED = 3 };

typedef struct msModuleRecord {
	const char* name;
	void (*init)(void);
	void (*deinit)(void);
	const int32_t* requested;
	int32_t requestedCount;
	int32_t status;
	bool hasTLA;
	int32_t dfsIndex;
	int32_t dfsAncestorIndex;
	void* error;
	bool asyncEvaluation;
	int32_t asyncOrdinal;
	int32_t pendingAsyncDeps;
	int32_t* asyncParents;
	int32_t asyncParentCount;
	int32_t cycleRoot;
	void* waiters;
} msModuleRecord;

extern int32_t msModuleEvalDepth;
extern void (*msModuleGuard)(msModuleRecord* record, void (*fn)(void));

void msModuleTableRegister(msModuleRecord* records, int32_t count);
msModuleRecord* msModuleBind(const char* name, void (*init)(void), void (*deinit)(void));
void* msModuleImport(msString name);
void msModuleAsyncBody(void* fut);
void msModuleDeinitLazy(void);

#endif /* MS_MODULE_EVAL_H */
