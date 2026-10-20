#ifndef MSOS_SOLANA

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "runtime/solana/solana.h"

#define MS_SOL_HOST_HEAP_SIZE (32 * 1024)
#define MS_SOL_HOST_COMPUTE_BUDGET 200000ULL
#define MS_SOL_HOST_REFUSED UINT64_MAX

static _Alignas(16) uint8_t msSolHostHeap[MS_SOL_HOST_HEAP_SIZE];
static const uint64_t msSolHostEmptyInput[6];
static msSolanaContext msSolHostState;
static uint64_t msSolHostAccounts[MS_SOL_MAX_ACCOUNTS];
static uint8_t* msSolHostInputBuffer;
static uint64_t msSolHostFaultCode;
static char msSolHostFaultText[160];

msSolanaContext* msSolHostContext(void) {
    if (msSolHostState.input == 0) {
        msSolHostState.input = (uint64_t)msSolHostEmptyInput;
        msSolHostState.arenaPosition = sizeof(msSolanaContext);
        msSolParse(msSolHostAccounts);
    }
    return &msSolHostState;
}

static void msSolHostFault(uint64_t result, const char* text) {
    if (msSolHostFaultCode != 0) return;
    msSolHostFaultCode = result;
    snprintf(msSolHostFaultText, sizeof(msSolHostFaultText), "%s", text);
}

uint64_t msSolHostAlloc(uint64_t size) {
    msSolanaContext* context = msSolHostContext();
    if (size <= UINT64_MAX - 7) size = (size + 7) & ~(uint64_t)7;
    if (size > MS_SOL_HOST_HEAP_SIZE - context->arenaPosition) {
        fprintf(stderr, "std/solana host: the 32 KiB program heap is exhausted (asked %llu more bytes at %llu)\n",
            (unsigned long long)size, (unsigned long long)context->arenaPosition);
        abort();
    }
    uint64_t address = (uint64_t)(msSolHostHeap + context->arenaPosition);
    context->arenaPosition += size;
    return address;
}

uint64_t msSolHostScratch(uint64_t size) {
    if (size > MS_SOL_HOST_HEAP_SIZE - msSolHostContext()->arenaPosition) return 0;
    return msSolHostAlloc(size);
}

uint64_t msSolHostReset(uint64_t input) {
    memset(msSolHostHeap, 0, sizeof(msSolHostHeap));
    memset(&msSolHostState, 0, sizeof(msSolHostState));
    msSolHostState.input = input == 0 ? (uint64_t)msSolHostEmptyInput : input;
    msSolHostState.arenaPosition = sizeof(msSolanaContext);
    msSolParse(msSolHostAccounts);
    msSolHostFaultCode = 0;
    msSolHostFaultText[0] = 0;
    return (uint64_t)msSolHostAccounts;
}

uint64_t msSolHostInput(uint64_t size) {
    free(msSolHostInputBuffer);
    msSolHostInputBuffer = (uint8_t*)calloc(1, (size_t)size);
    if (msSolHostInputBuffer == NULL) abort();
    return (uint64_t)msSolHostInputBuffer;
}

uint64_t msSolHostResult(void) { return msSolHostState.result; }
uint64_t msSolHostFaultCodeOf(void) { return msSolHostFaultCode; }
msString msSolHostFaultMessage(void) { return msStringNew(msSolHostFaultText, (int64_t)strlen(msSolHostFaultText)); }

uint64_t msSolHostRemainingComputeUnits(void) { return MS_SOL_HOST_COMPUTE_BUDGET; }

void msSolHostCopy(uint64_t destination, uint64_t source, uint64_t length) {
    if ((destination < source + length) && (source < destination + length)) {
        msSolHostFault(MS_SOL_HOST_REFUSED, "ProgramFailedToComplete: sol_memcpy_: Overlapping copy");
        return;
    }
    memcpy((void*)destination, (const void*)source, (size_t)length);
}

void msSolHostFill(uint64_t destination, uint8_t value, uint64_t length) {
    memset((void*)destination, value, (size_t)length);
}

int32_t msSolHostCompare(uint64_t left, uint64_t right, uint64_t length) {
    const uint8_t* a = (const uint8_t*)left;
    const uint8_t* b = (const uint8_t*)right;
    for (uint64_t index = 0; index < length; index++) {
        if (a[index] != b[index]) return (int32_t)a[index] - (int32_t)b[index];
    }
    return 0;
}

#define MS_SOL_HOST_SEED_TOO_LONG "Length of the seed is too long for address generation"

void msSolHostRaise(uint64_t code, msString text) {
    char line[256];
    snprintf(line, sizeof(line), "%.*s", (int)text.len, text.p == NULL ? "" : (const char*)text.p->data);
    msSolHostFault(code, line);
}

#endif