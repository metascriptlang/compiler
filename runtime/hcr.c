#include "runtime/hcr.h"
#include "runtime/hcrEngine.h"
#include "runtime/types.h"
#include "runtime/hcrTls.h"
#include <stddef.h>
#include <string.h>

#if defined(_WIN32) && defined(MS_HCR_CORE)
uint32_t msHcrTlsIndex;
#endif

typedef struct MsHcrStorage {
	struct MsHcrStorage* next;
	max_align_t data[];
} MsHcrStorage;

typedef struct MsHcrModule MsHcrModule;

typedef struct MsHcrEntry {
	struct MsHcrEntry* hashNext;
	struct MsHcrEntry* moduleNext;
	MsHcrModule* module;
	char* symbol;
	char* key;
	uint64_t hash;
	MsHcrCell cell;
	void* candidate;
	void* saved;
	MsHcrStorage* storage;
	MsHcrStorage* candidateStorage;
	MsHcrStorage* savedStorage;
	size_t size;
	int active;
	int candidateActive;
	int candidateForwards;
	int savedActive;
	void* previous;
	MsHcrStorage* previousStorage;
	int previousActive;
} MsHcrEntry;

struct MsHcrModule {
	MsHcrModule* next;
	char* id;
	MsHcrEntry* entries;
	MsHcrStorage* retired;
	int active;
	int savedActive;
	int phase;
	int previousActive;
	int revertible;
};

typedef struct MsHcrTypeEntry {
	struct MsHcrTypeEntry* next;
	MsHcrModule* module;
	char* name;
	msTypeInfo info;
	msTypeInfo saved;
	msTypeInfo previous;
	int created;
	int exposed;
	int revertible;
} MsHcrTypeEntry;

static MsHcrModule* msHcrModules[256];
static MsHcrEntry** msHcrEntries = NULL;
static size_t msHcrEntryCount = 0;
static size_t msHcrBucketCount = 0;
static MsHcrTypeEntry* msHcrTypes = NULL;
static int msHcrStaging = 0;
static char* msHcrDir = NULL;
static char* msHcrStem = NULL;

static void msHcrFail(const char* moduleId, const char* reason) {
	fprintf(stderr, "HCR: module '%s': %s\n", moduleId != NULL ? moduleId : "<null>", reason);
	abort();
}

static void* msHcrAllocate(size_t size) {
	void* result = calloc(1, size);
	if (result == NULL) msHcrFail(NULL, "cannot allocate registry storage");
	return result;
}

static void msHcrText(const char* text, const char* what) {
	if (text == NULL || *text == '\0') msHcrFail(text, what);
}

static char* msHcrCopy(const char* text, const char* what) {
	if (text == NULL) msHcrFail(NULL, what);
	size_t length = strlen(text);
	char* copy = (char*)msHcrAllocate(length + 1);
	memcpy(copy, text, length + 1);
	return copy;
}

static uint64_t msHcrHash(uint64_t hash, const char* text) {
	for (const unsigned char* p = (const unsigned char*)text; *p != 0; ++p) {
		hash = (hash ^ *p) * UINT64_C(1099511628211);
	}
	return hash * UINT64_C(1099511628211);
}

static MsHcrModule* msHcrModule(const char* moduleId) {
	msHcrText(moduleId, "missing module identity");
	size_t bucket = (size_t)(msHcrHash(UINT64_C(14695981039346656037), moduleId) & 255);
	for (MsHcrModule* module = msHcrModules[bucket]; module != NULL; module = module->next) {
		if (strcmp(module->id, moduleId) == 0) return module;
	}
	MsHcrModule* module = (MsHcrModule*)msHcrAllocate(sizeof(MsHcrModule));
	module->id = msHcrCopy(moduleId, "missing module identity");
	module->next = msHcrModules[bucket];
	msHcrModules[bucket] = module;
	return module;
}

static void msHcrGrow(void) {
	size_t count = msHcrBucketCount == 0 ? 256 : msHcrBucketCount * 2;
	if (count < msHcrBucketCount || count > SIZE_MAX / sizeof(MsHcrEntry*)) {
		msHcrFail(NULL, "symbol registry size overflow");
	}
	MsHcrEntry** buckets = (MsHcrEntry**)msHcrAllocate(count * sizeof(MsHcrEntry*));
	for (size_t i = 0; i < msHcrBucketCount; ++i) {
		MsHcrEntry* entry = msHcrEntries[i];
		while (entry != NULL) {
			MsHcrEntry* next = entry->hashNext;
			size_t bucket = (size_t)entry->hash & (count - 1);
			entry->hashNext = buckets[bucket];
			buckets[bucket] = entry;
			entry = next;
		}
	}
	free(msHcrEntries);
	msHcrEntries = buckets;
	msHcrBucketCount = count;
}

static MsHcrEntry* msHcrEntry(const char* moduleId, const char* symbol, const char* key) {
	msHcrText(symbol, "missing C symbol name");
	msHcrText(key, "missing symbol contract key");
	if ((key[0] != 'f' && key[0] != 'v') || key[1] != ':' || key[2] == '\0') {
		msHcrFail(moduleId, "malformed symbol kind or contract key");
	}
	MsHcrModule* module = msHcrModule(moduleId);
	uint64_t hash = msHcrHash(msHcrHash(msHcrHash(UINT64_C(14695981039346656037), moduleId), symbol), key);
	if (msHcrBucketCount == 0) msHcrGrow();
	size_t bucket = (size_t)hash & (msHcrBucketCount - 1);
	for (MsHcrEntry* entry = msHcrEntries[bucket]; entry != NULL; entry = entry->hashNext) {
		if (entry->hash == hash && entry->module == module && strcmp(entry->symbol, symbol) == 0 && strcmp(entry->key, key) == 0) return entry;
	}
	if (msHcrEntryCount >= msHcrBucketCount - msHcrBucketCount / 4) {
		msHcrGrow();
		bucket = (size_t)hash & (msHcrBucketCount - 1);
	}
	MsHcrEntry* entry = (MsHcrEntry*)msHcrAllocate(sizeof(MsHcrEntry));
	entry->module = module;
	entry->symbol = msHcrCopy(symbol, "missing C symbol name");
	entry->key = msHcrCopy(key, "missing symbol contract key");
	entry->hash = hash;
	entry->hashNext = msHcrEntries[bucket];
	msHcrEntries[bucket] = entry;
	entry->moduleNext = module->entries;
	module->entries = entry;
	++msHcrEntryCount;
	return entry;
}

MsHcrCell* msHcrBind(const char* moduleId, const char* symbol, const char* key) {
	return &msHcrEntry(moduleId, symbol, key)->cell;
}

int32_t msHcrModuleBegin(const char* moduleId) {
	MsHcrModule* module = msHcrModule(moduleId);
	if (module->phase != 0) msHcrFail(moduleId, "module registration already pending");
	if (msHcrStaging) {
		module->phase = 1;
		return module->active ? 0 : 1;
	}
	if (module->active) msHcrFail(moduleId, "accepted module registration requires staging");
	module->active = 1;
	return 1;
}

static void msHcrRegistration(MsHcrEntry* entry, char kind) {
	MsHcrModule* module = entry->module;
	if (entry->key[0] != kind) msHcrFail(module->id, "registration kind does not match the contract key");
	if (msHcrStaging) {
		if (module->phase != 1) msHcrFail(module->id, "registration requires a staged module begin");
		if (entry->candidateActive) msHcrFail(module->id, "symbol registered twice in one candidate");
	} else {
		if (!module->active || module->phase != 0) msHcrFail(module->id, "registration requires an initial module begin");
		if (entry->active) msHcrFail(module->id, "symbol registered twice in the accepted image");
	}
}

MsHcrCell* msHcrRegisterFunction(const char* moduleId, const char* symbol, const char* key, void* address, int32_t forwards) {
	if (address == NULL) msHcrFail(moduleId, "cannot register a null function address");
	MsHcrEntry* entry = msHcrEntry(moduleId, symbol, key);
	msHcrRegistration(entry, 'f');
	if (msHcrStaging) {
		entry->candidate = address;
		entry->candidateActive = 1;
		entry->candidateForwards = forwards;
	} else {
		entry->cell.current = address;
		if (forwards && entry->cell.entry == NULL) entry->cell.entry = address;
		entry->active = 1;
	}
	return &entry->cell;
}

int32_t msHcrRegisterVariable(const char* moduleId, const char* symbol, const char* key, size_t size, void** out) {
	if (out == NULL || size == 0 || size > SIZE_MAX - offsetof(MsHcrStorage, data)) {
		msHcrFail(moduleId, "invalid variable storage size or output pointer");
	}
	MsHcrEntry* entry = msHcrEntry(moduleId, symbol, key);
	msHcrRegistration(entry, 'v');
	if (entry->size != 0 && entry->size != size) msHcrFail(moduleId, "variable size changed without a changed contract key");
	entry->size = size;
	int fresh = !entry->active;
	MsHcrStorage* storage = entry->storage;
	if (fresh) storage = (MsHcrStorage*)msHcrAllocate(offsetof(MsHcrStorage, data) + size);
	*out = (void*)storage->data;
	if (msHcrStaging) {
		entry->candidate = *out;
		entry->candidateStorage = storage;
		entry->candidateActive = 1;
	} else {
		entry->storage = storage;
		entry->cell.current = *out;
		entry->active = 1;
	}
	return fresh ? 1 : 0;
}

void msHcrStageBegin(void) {
	if (msHcrStaging) msHcrFail(NULL, "nested staging is invalid");
	for (size_t i = 0; i < 256; ++i) {
		for (MsHcrModule* module = msHcrModules[i]; module != NULL; module = module->next) {
			if (module->phase != 0) msHcrFail(module->id, "previous transaction has not been resolved");
		}
	}
	for (MsHcrTypeEntry* entry = msHcrTypes; entry != NULL; entry = entry->next) {
		entry->saved = entry->info;
		entry->created = 0;
		entry->exposed = 0;
	}
	msHcrStaging = 1;
}

void msHcrStageEnd(void) {
	if (!msHcrStaging) msHcrFail(NULL, "staging was not begun");
	msHcrStaging = 0;
}

int32_t msHcrStaged(const char* moduleId) {
	return msHcrModule(moduleId)->phase == 1 ? 1 : 0;
}

void msHcrCommit(const char* moduleId) {
	MsHcrModule* module = msHcrModule(moduleId);
	if (msHcrStaging || module->phase != 1) msHcrFail(moduleId, "commit requires completed module staging");
	module->savedActive = module->active;
	for (MsHcrEntry* entry = module->entries; entry != NULL; entry = entry->moduleNext) {
		entry->saved = entry->cell.current;
		entry->savedStorage = entry->storage;
		entry->savedActive = entry->active;
		entry->cell.current = entry->candidateActive ? entry->candidate : entry->saved;
		if (entry->candidateActive && entry->candidateForwards && entry->cell.entry == NULL) entry->cell.entry = entry->candidate;
		entry->storage = entry->candidateActive ? entry->candidateStorage : entry->savedStorage;
		entry->active = entry->candidateActive;
		entry->candidate = NULL;
		entry->candidateStorage = NULL;
		entry->candidateActive = 0;
		entry->candidateForwards = 0;
	}
	for (MsHcrTypeEntry* entry = msHcrTypes; entry != NULL; entry = entry->next) {
		if (entry->module == module && entry->created) entry->exposed = 1;
	}
	module->active = 1;
	module->phase = 2;
}

static void msHcrRetire(MsHcrModule* module, MsHcrStorage* storage) {
	if (storage == NULL) return;
	storage->next = module->retired;
	module->retired = storage;
}

static void msHcrAcceptTypeSnapshots(MsHcrModule* module) {
	for (MsHcrTypeEntry* entry = msHcrTypes; entry != NULL; entry = entry->next) {
		if (entry->module != module) continue;
		entry->saved = entry->info;
		entry->created = 0;
		entry->exposed = 0;
	}
}

void msHcrRollback(const char* moduleId) {
	MsHcrModule* module = msHcrModule(moduleId);
	if (msHcrStaging || module->phase != 2) msHcrFail(moduleId, "rollback requires a committed module");
	for (MsHcrEntry* entry = module->entries; entry != NULL; entry = entry->moduleNext) {
		if (entry->storage != entry->savedStorage) msHcrRetire(module, entry->storage);
		entry->cell.current = entry->saved;
		entry->storage = entry->savedStorage;
		entry->active = entry->savedActive;
		entry->saved = NULL;
		entry->savedStorage = NULL;
		entry->savedActive = 0;
	}
	msHcrRestoreTypeInfos(moduleId);
	msHcrAcceptTypeSnapshots(module);
	module->active = module->savedActive;
	module->savedActive = 0;
	module->phase = 0;
}

void msHcrDiscard(const char* moduleId) {
	MsHcrModule* module = msHcrModule(moduleId);
	if (module->phase == 2) msHcrFail(moduleId, "cannot discard a committed module; roll it back");
	if (module->phase == 0) return;
	for (MsHcrEntry* entry = module->entries; entry != NULL; entry = entry->moduleNext) {
		if (entry->candidateStorage != entry->storage) free(entry->candidateStorage);
		entry->candidate = NULL;
		entry->candidateStorage = NULL;
		entry->candidateActive = 0;
		entry->candidateForwards = 0;
	}
	msHcrRestoreTypeInfos(moduleId);
	msHcrAcceptTypeSnapshots(module);
	module->phase = 0;
}

void msHcrFinalize(const char* moduleId) {
	MsHcrModule* module = msHcrModule(moduleId);
	if (msHcrStaging || module->phase != 2) msHcrFail(moduleId, "finalize requires a committed module");
	for (MsHcrEntry* entry = module->entries; entry != NULL; entry = entry->moduleNext) {
		if (module->revertible && entry->previousStorage != entry->savedStorage && entry->previousStorage != entry->storage) {
			msHcrRetire(module, entry->previousStorage);
		}
		entry->previous = entry->saved;
		entry->previousStorage = entry->savedStorage;
		entry->previousActive = entry->savedActive;
		entry->saved = NULL;
		entry->savedStorage = NULL;
		entry->savedActive = 0;
	}
	for (MsHcrTypeEntry* entry = msHcrTypes; entry != NULL; entry = entry->next) {
		if (entry->module != module) continue;
		entry->previous = entry->saved;
		entry->revertible = 1;
	}
	msHcrAcceptTypeSnapshots(module);
	module->previousActive = module->savedActive;
	module->revertible = 1;
	module->savedActive = 0;
	module->phase = 0;
}

void msHcrRevert(const char* moduleId) {
	MsHcrModule* module = msHcrModule(moduleId);
	if (msHcrStaging || module->phase != 0 || !module->revertible) msHcrFail(moduleId, "revert requires an accepted reload of the module");
	for (MsHcrEntry* entry = module->entries; entry != NULL; entry = entry->moduleNext) {
		if (entry->storage != entry->previousStorage) msHcrRetire(module, entry->storage);
		entry->cell.current = entry->previous;
		entry->storage = entry->previousStorage;
		entry->active = entry->previousActive;
		entry->previous = NULL;
		entry->previousStorage = NULL;
		entry->previousActive = 0;
	}
	for (MsHcrTypeEntry* entry = msHcrTypes; entry != NULL; entry = entry->next) {
		if (entry->module != module || !entry->revertible) continue;
		entry->info = entry->previous;
		entry->saved = entry->previous;
		entry->revertible = 0;
	}
	module->active = module->previousActive;
	module->previousActive = 0;
	module->revertible = 0;
}

int32_t msHcrInvokeInit(void* raw) { return msHcrCallInitStatus(raw); }

void* msHcrTypeInfo(const char* moduleId, const char* typeName) {
	msHcrText(typeName, "missing TypeInfo name");
	MsHcrModule* module = msHcrModule(moduleId);
	for (MsHcrTypeEntry* entry = msHcrTypes; entry != NULL; entry = entry->next) {
		if (entry->module == module && strcmp(entry->name, typeName) == 0) return &entry->info;
	}
	MsHcrTypeEntry* entry = (MsHcrTypeEntry*)msHcrAllocate(sizeof(MsHcrTypeEntry));
	entry->module = module;
	entry->name = msHcrCopy(typeName, "missing TypeInfo name");
	entry->created = msHcrStaging;
	entry->next = msHcrTypes;
	msHcrTypes = entry;
	return &entry->info;
}

void msHcrRestoreTypeInfos(const char* moduleId) {
	MsHcrModule* module = msHcrModule(moduleId);
	for (MsHcrTypeEntry* entry = msHcrTypes; entry != NULL; entry = entry->next) {
		if (entry->module == module && !(entry->created && entry->exposed)) entry->info = entry->saved;
	}
}

void msHcrLaunch(const char* dir, const char* stem) {
	if (msHcrDir != NULL) {
		fprintf(stderr, "HCR: the engine was already launched from '%s'\n", msHcrDir);
		abort();
	}
	msHcrDir = msHcrCopy(dir, "launch directory");
	msHcrStem = msHcrCopy(stem, "launch stem");
	msHcrCoreInit();
}

msString msHcrLaunchDir(void) { return msStringFromCStr(msHcrDir != NULL ? msHcrDir : ""); }

msString msHcrLaunchStem(void) { return msStringFromCStr(msHcrStem != NULL ? msHcrStem : ""); }

/* Windows resumes a guard from its captured register context: the fatal trap restores it
 * directly, the vectored handler hands it back to the OS, so nothing jumps out of the dispatcher. */
#if defined(_WIN32)
int __cdecl _resetstkoflw(void);
#else
#include <setjmp.h>
#include <signal.h>
#include <pthread.h>
#endif

enum { MS_HCR_GUARD_OK = 0, MS_HCR_GUARD_FAULT = 1, MS_HCR_GUARD_FATAL = 2, MS_HCR_GUARD_THREW = 3 };

typedef struct MsHcrGuard {
#if defined(_WIN32)
	CONTEXT context;
#else
	sigjmp_buf env;
#endif
	volatile int kind;
	volatile unsigned long code;
	volatile uintptr_t address;
} MsHcrGuard;

static MsHcrGuard* volatile msHcrGuardActive = NULL;
static volatile unsigned long msHcrGuardOwner = 0;
static char msHcrGuardReason[512];
static int msHcrGuardInstalled = 0;

#if defined(_WIN32)
static unsigned long msHcrGuardThread(void) { return (unsigned long)GetCurrentThreadId(); }
#else
static unsigned long msHcrGuardThread(void) { return (unsigned long)pthread_self(); }
#endif

static MsHcrGuard* msHcrGuardHere(void) {
	MsHcrGuard* guard = msHcrGuardActive;
	return guard != NULL && msHcrGuardOwner == msHcrGuardThread() ? guard : NULL;
}

static void msHcrGuardFatal(void) {
	MsHcrGuard* guard = msHcrGuardHere();
	if (guard == NULL) return;
	guard->kind = MS_HCR_GUARD_FATAL;
#if defined(_WIN32)
	RtlRestoreContext(&guard->context, NULL);
#else
	siglongjmp(guard->env, 1);
#endif
}

#if defined(_WIN32)
static LONG CALLBACK msHcrGuardException(EXCEPTION_POINTERS* info) {
	DWORD code = info->ExceptionRecord->ExceptionCode;
	switch (code) {
	case EXCEPTION_ACCESS_VIOLATION:
	case EXCEPTION_ILLEGAL_INSTRUCTION:
	case EXCEPTION_PRIV_INSTRUCTION:
	case EXCEPTION_INT_DIVIDE_BY_ZERO:
	case EXCEPTION_INT_OVERFLOW:
	case EXCEPTION_DATATYPE_MISALIGNMENT:
	case EXCEPTION_ARRAY_BOUNDS_EXCEEDED:
	case EXCEPTION_STACK_OVERFLOW:
		break;
	default:
		return EXCEPTION_CONTINUE_SEARCH;
	}
	MsHcrGuard* guard = msHcrGuardHere();
	if (guard == NULL) return EXCEPTION_CONTINUE_SEARCH;
	guard->kind = MS_HCR_GUARD_FAULT;
	guard->code = code;
	guard->address = (uintptr_t)info->ExceptionRecord->ExceptionAddress;
	CONTEXT* to = info->ContextRecord;
	const CONTEXT* from = &guard->context;
	to->Rip = from->Rip;
	to->Rsp = from->Rsp;
	to->Rbp = from->Rbp;
	to->Rbx = from->Rbx;
	to->Rsi = from->Rsi;
	to->Rdi = from->Rdi;
	to->R12 = from->R12;
	to->R13 = from->R13;
	to->R14 = from->R14;
	to->R15 = from->R15;
	to->Rax = from->Rax;
	to->Rcx = from->Rcx;
	to->Rdx = from->Rdx;
	to->R8 = from->R8;
	to->R9 = from->R9;
	to->R10 = from->R10;
	to->R11 = from->R11;
	to->EFlags = from->EFlags;
	to->MxCsr = from->MxCsr;
	return EXCEPTION_CONTINUE_EXECUTION;
}

static void msHcrGuardInstall(void) {
	if (msHcrGuardInstalled) return;
	msHcrGuardInstalled = 1;
	ULONG reserve = 65536;
	SetThreadStackGuarantee(&reserve);
	AddVectoredExceptionHandler(1, msHcrGuardException);
	msFatalTrap = msHcrGuardFatal;
}

static const char* msHcrGuardFaultName(unsigned long code) {
	switch (code) {
	case EXCEPTION_ACCESS_VIOLATION: return "access violation";
	case EXCEPTION_ILLEGAL_INSTRUCTION: return "illegal instruction";
	case EXCEPTION_PRIV_INSTRUCTION: return "privileged instruction";
	case EXCEPTION_INT_DIVIDE_BY_ZERO: return "integer division by zero";
	case EXCEPTION_INT_OVERFLOW: return "integer overflow";
	case EXCEPTION_DATATYPE_MISALIGNMENT: return "misaligned access";
	case EXCEPTION_ARRAY_BOUNDS_EXCEEDED: return "array bounds exceeded";
	case EXCEPTION_STACK_OVERFLOW: return "stack overflow";
	default: return "fault";
	}
}
#else
static const int msHcrGuardSignals[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT };
static struct sigaction msHcrGuardPrevious[sizeof(msHcrGuardSignals) / sizeof(msHcrGuardSignals[0])];
static _Thread_local void* msHcrGuardAltStack = NULL;

static void msHcrGuardSignal(int sig, siginfo_t* info, void* context) {
	(void)context;
	MsHcrGuard* guard = msHcrGuardHere();
	if (guard == NULL) {
		for (size_t i = 0; i < sizeof(msHcrGuardSignals) / sizeof(msHcrGuardSignals[0]); i++) {
			if (msHcrGuardSignals[i] == sig) sigaction(sig, &msHcrGuardPrevious[i], NULL);
		}
		if (sig == SIGABRT) raise(sig);
		return;
	}
	guard->kind = MS_HCR_GUARD_FAULT;
	guard->code = (unsigned long)sig;
	guard->address = (uintptr_t)info->si_addr;
	siglongjmp(guard->env, 1);
}

static void msHcrGuardInstall(void) {
	if (msHcrGuardAltStack == NULL) {
		size_t size = 65536;
		msHcrGuardAltStack = malloc(size);
		stack_t stack;
		stack.ss_sp = msHcrGuardAltStack;
		stack.ss_size = size;
		stack.ss_flags = 0;
		sigaltstack(&stack, NULL);
	}
	if (msHcrGuardInstalled) return;
	msHcrGuardInstalled = 1;
	struct sigaction action;
	memset(&action, 0, sizeof(action));
	action.sa_sigaction = msHcrGuardSignal;
	action.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_NODEFER;
	sigemptyset(&action.sa_mask);
	for (size_t i = 0; i < sizeof(msHcrGuardSignals) / sizeof(msHcrGuardSignals[0]); i++) {
		sigaction(msHcrGuardSignals[i], &action, &msHcrGuardPrevious[i]);
	}
	msFatalTrap = msHcrGuardFatal;
}

static const char* msHcrGuardFaultName(unsigned long code) {
	switch ((int)code) {
	case SIGSEGV: return "segmentation fault";
	case SIGBUS: return "bus error";
	case SIGILL: return "illegal instruction";
	case SIGFPE: return "arithmetic fault";
	case SIGABRT: return "abort";
	default: return "fault";
	}
}
#endif

typedef struct MsHcrGuardCall {
	void* fn;
	void* env;
	int32_t status;
	int kind;
} MsHcrGuardCall;

static void msHcrGuardInvoke(MsHcrGuardCall* call) {
	if (call->kind == 0) ((void (*)(void*))call->fn)(call->env);
	else if (call->kind == 1) ((void (*)(void))call->fn)();
	else call->status = ((int32_t (*)(void))call->fn)();
}

static int32_t msHcrGuarded(MsHcrGuardCall* call) {
	MsHcrGuard guard;
	guard.kind = MS_HCR_GUARD_OK;
	guard.code = 0;
	guard.address = 0;
	MsHcrGuard* volatile outer = msHcrGuardActive;
	volatile unsigned long outerOwner = msHcrGuardOwner;
	msHcrGuardReason[0] = 0;
	msHcrGuardInstall();
#if defined(_WIN32)
	RtlCaptureContext(&guard.context);
	if (guard.kind == MS_HCR_GUARD_OK) {
#else
	if (sigsetjmp(guard.env, 1) == 0) {
#endif
		msHcrGuardOwner = msHcrGuardThread();
		msHcrGuardActive = &guard;
		msHcrGuardInvoke(call);
		msHcrGuardActive = outer;
		msHcrGuardOwner = outerOwner;
		if (!msErr) return MS_HCR_GUARD_OK;
		guard.kind = MS_HCR_GUARD_THREW;
	}
	msHcrGuardActive = outer;
	msHcrGuardOwner = outerOwner;
	const int kind = guard.kind;
	const unsigned long code = guard.code;
	const uintptr_t address = guard.address;
#if defined(_WIN32)
	if (kind == MS_HCR_GUARD_FAULT && code == EXCEPTION_STACK_OVERFLOW) _resetstkoflw();
#endif
	if (kind == MS_HCR_GUARD_FAULT) {
		snprintf(msHcrGuardReason, sizeof(msHcrGuardReason), "%s at %p", msHcrGuardFaultName(code), (void*)address);
	} else if (kind == MS_HCR_GUARD_FATAL) {
		snprintf(msHcrGuardReason, sizeof(msHcrGuardReason), "a fatal runtime error (reported above)");
	} else {
		msString message = msCurrException != NULL ? ((msError*)msCurrException)->message : MS_EMPTY_STRING;
		snprintf(msHcrGuardReason, sizeof(msHcrGuardReason), "an uncaught exception: %.*s",
		         (int)(message.len < 400 ? message.len : 400), message.p != NULL ? message.p->data : "");
	}
	if (msCurrException != NULL) msDecref((void*)msCurrException);
	msCurrException = NULL;
	msErr = false;
	return kind;
}

int32_t msHcrGuardRun(msClosure body) {
	MsHcrGuardCall call = { (void*)body.fn, body.env, 0, 0 };
	return msHcrGuarded(&call);
}

int32_t msHcrGuardInit(void* raw) {
	MsHcrGuardCall call = { raw, NULL, 0, 1 };
	return msHcrGuarded(&call) != MS_HCR_GUARD_OK ? 1 : 0;
}

int32_t msHcrGuardProbe(void* raw) {
	MsHcrGuardCall call = { raw, NULL, 0, 2 };
	return msHcrGuarded(&call) != MS_HCR_GUARD_OK ? 1 : call.status;
}

msString msHcrGuardText(void) { return msStringFromCStr(msHcrGuardReason); }
