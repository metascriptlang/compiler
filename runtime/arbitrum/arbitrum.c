#include "runtime/manual.h"
#include "runtime/arbitrum/arbitrum.h"

#define MS_ARB_HOOK(name) \
    __attribute__((import_module("vm_hooks"), import_name(#name)))

MS_ARB_HOOK(read_args) extern void msArbReadArgs(uint8_t* destination);
MS_ARB_HOOK(write_result) extern void msArbWriteResult(const uint8_t* data, uint32_t length);
MS_ARB_HOOK(storage_load_bytes32)
extern void msArbLoadStorage(const uint8_t* key, uint8_t* destination);
MS_ARB_HOOK(storage_cache_bytes32)
extern void msArbCacheStorage(const uint8_t* key, const uint8_t* value);
MS_ARB_HOOK(storage_flush_cache) extern void msArbFlushStorage(uint32_t clear);
MS_ARB_HOOK(msg_sender) extern void msArbReadSender(uint8_t* destination);
MS_ARB_HOOK(contract_address) extern void msArbReadAddress(uint8_t* destination);
MS_ARB_HOOK(msg_value) extern void msArbReadValue(uint8_t* destination);
MS_ARB_HOOK(pay_for_memory_grow) extern void msArbPayForMemoryGrow(uint16_t pages);
MS_ARB_HOOK(emit_log) extern void msArbEmitLog(const uint8_t* data, uint32_t length, uint32_t topics);

extern void MsMain(void);

static struct {
    uint8_t* calldata;
    uint32_t length;
    int32_t status;
    bool finished;
    uint8_t scratch[64];
} msArbContext;

__attribute__((export_name("mark_used")))
void msArbMarkUsed(void) {
    msArbPayForMemoryGrow(0);
}

__attribute__((export_name("user_entrypoint")))
int32_t user_entrypoint(uint32_t argsLength) {
    msArenaReset();
    msArbContext.calldata = (uint8_t*)(uintptr_t)msArbAllocate(argsLength);
    if (msArbContext.calldata == NULL) __builtin_trap();
    msArbContext.length = argsLength;
    msArbContext.status = 1;
    msArbContext.finished = false;
    msArbReadArgs(msArbContext.calldata);
    MsMain();
    msArbFlushStorage(0);
    return msArbContext.status;
}

uint32_t msArbCalldataAddress(void) {
    return (uint32_t)(uintptr_t)msArbContext.calldata;
}

uint32_t msArbCalldataLength(void) {
    return msArbContext.length;
}

uint32_t msArbScratch(void) {
    return (uint32_t)(uintptr_t)msArbContext.scratch;
}

uint32_t msArbAllocate(uint32_t length) {
    if (length > UINT32_MAX - 7) return 0;
    return (uint32_t)(uintptr_t)msArenaAlloc(length == 0 ? 1 : length);
}

void msArbSetResult(uint32_t address, uint32_t length, int32_t status) {
    if (msArbContext.finished) __builtin_trap();
    msArbWriteResult((const uint8_t*)(uintptr_t)address, length);
    msArbContext.status = status;
    msArbContext.finished = true;
}

void msArbStorageLoad(uint32_t key, uint32_t destination) {
    msArbLoadStorage((const uint8_t*)(uintptr_t)key, (uint8_t*)(uintptr_t)destination);
}

void msArbStorageStore(uint32_t key, uint32_t value) {
    msArbCacheStorage((const uint8_t*)(uintptr_t)key, (const uint8_t*)(uintptr_t)value);
}

void msArbMsgSender(uint32_t destination) {
    msArbReadSender((uint8_t*)(uintptr_t)destination);
}

void msArbContractAddress(uint32_t destination) {
    msArbReadAddress((uint8_t*)(uintptr_t)destination);
}

void msArbMsgValue(uint32_t destination) {
    msArbReadValue((uint8_t*)(uintptr_t)destination);
}

void msPrintln(msString value) {
    if (value.len < 0 || (uint64_t)value.len > UINT32_MAX) __builtin_trap();
    const uint8_t* bytes = value.len == 0 ? (const uint8_t*)"" : (const uint8_t*)value.p->data;
    msArbEmitLog(bytes, (uint32_t)value.len, 0);
}
