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
} MsHcrEntry;

struct MsHcrModule {
	MsHcrModule* next;
	char* id;
	MsHcrEntry* entries;
	MsHcrStorage* retired;
	int active;
	int savedActive;
	int phase;
};

typedef struct MsHcrTypeEntry {
	struct MsHcrTypeEntry* next;
	MsHcrModule* module;
	char* name;
	msTypeInfo info;
	msTypeInfo saved;
	int created;
	int exposed;
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
		if (entry->savedStorage != entry->storage) msHcrRetire(module, entry->savedStorage);
		entry->saved = NULL;
		entry->savedStorage = NULL;
		entry->savedActive = 0;
	}
	msHcrAcceptTypeSnapshots(module);
	module->savedActive = 0;
	module->phase = 0;
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
