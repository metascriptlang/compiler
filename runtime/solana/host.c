#ifndef MSOS_SOLANA

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "runtime/solana/solana.h"

#define MS_SOL_HOST_HEAP_SIZE (32 * 1024)
#define MS_SOL_HOST_COMPUTE_BUDGET 200000ULL
#define MS_SOL_MAX_SEEDS 16
#define MS_SOL_MAX_SIGNERS 16
#define MS_SOL_MAX_SEED_LEN 32
#define MS_SOL_HOST_REFUSED UINT64_MAX
#define MS_SOL_HOST_NOT_SIMULATED (UINT64_MAX - 1)

typedef struct {
    uint8_t program[32];
    uint64_t metaCount;
    uint8_t* metas;
    uint64_t dataLength;
    uint8_t* data;
    uint64_t signerCount;
    uint8_t* signerSeeds;
} msSolHostInvocation;

typedef struct {
    uint8_t* record;
    uint64_t index;
    uint64_t startLamports;
    uint64_t startLength;
    uint64_t lamports;
    uint64_t length;
    uint8_t owner[32];
    uint8_t* data;
} msSolHostHeld;

static _Alignas(16) uint8_t msSolHostHeap[MS_SOL_HOST_HEAP_SIZE];
static const uint64_t msSolHostEmptyInput[6];
static msSolanaContext msSolHostState;
static uint64_t msSolHostAccounts[MS_SOL_MAX_ACCOUNTS];
static uint8_t* msSolHostInputBuffer;
static uint64_t msSolHostFaultCode;
static char msSolHostFaultText[160];
static msSolHostInvocation* msSolHostInvocations;
static uint64_t msSolHostInvocationCount;
static msSolHostHeld msSolHostHolds[MS_SOL_MAX_ACCOUNTS];
static uint64_t msSolHostHoldCount;
static void msSolHostHoldAccounts(void);
void msSolHostResetSimulator(void);
void msSolHostClearReturnData(void);
void msSolHostSetReturnDataAt(uint64_t data, uint64_t length);

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

static void msSolHostForget(void) {
    msSolHostResetSimulator();
    for (uint64_t index = 0; index < msSolHostInvocationCount; index++) {
        free(msSolHostInvocations[index].metas);
        free(msSolHostInvocations[index].data);
        free(msSolHostInvocations[index].signerSeeds);
    }
    free(msSolHostInvocations);
    msSolHostInvocations = NULL;
    msSolHostInvocationCount = 0;
    for (uint64_t index = 0; index < msSolHostHoldCount; index++) free(msSolHostHolds[index].data);
    msSolHostHoldCount = 0;
}

void msSolHostEnter(uint64_t input) {
    msSolHostForget();
    memset(msSolHostHeap, 0, sizeof(msSolHostHeap));
    memset(&msSolHostState, 0, sizeof(msSolHostState));
    msSolHostState.input = input == 0 ? (uint64_t)msSolHostEmptyInput : input;
    msSolHostState.arenaPosition = sizeof(msSolanaContext);
    msSolParse(msSolHostAccounts);
    msSolHostHoldAccounts();
    msSolHostFaultCode = 0;
    msSolHostFaultText[0] = 0;
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

uint64_t msSolHostInvocationTotal(void) { return msSolHostInvocationCount; }

uint64_t msSolHostInvocationAt(uint64_t index) {
    return index < msSolHostInvocationCount ? (uint64_t)&msSolHostInvocations[index] : 0;
}

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

uint64_t msSolHostDeriveAddress(uint64_t seeds, uint64_t count, uint64_t bump, uint64_t programId, uint64_t out);

static int msSolHostDerive(uint64_t seeds, uint64_t count, const uint8_t* bump, uint64_t programId, uint8_t out[32]) {
    return (int)msSolHostDeriveAddress(seeds, count, (uint64_t)(uintptr_t)bump, programId, (uint64_t)(uintptr_t)out);
}

uint64_t msSolHostRecordAddress(uint64_t header, uint64_t index);
uint64_t msSolHostLamportsOf(uint64_t record);
uint64_t msSolHostRentExemptFor(uint64_t length);
uint64_t msSolHostAnyByteIn(uint64_t bytes, uint64_t from, uint64_t to);
uint64_t msSolHostSystemInvoke(uint64_t header);


static uint8_t* msSolHostRecordOf(const uint64_t* header, uint64_t index) {
    return (uint8_t*)(uintptr_t)msSolHostRecordAddress((uint64_t)(uintptr_t)header, index);
}

static uint64_t msSolHostLamports(const uint8_t* record) {
    return msSolHostLamportsOf((uint64_t)(uintptr_t)record);
}

static uint64_t msSolHostRentExempt(uint64_t length) {
    return msSolHostRentExemptFor(length);
}

#define MS_SOL_HOST_MISSING_REQUIRED_SIGNATURE (8ULL << 32)

static const uint8_t msSolHostTokenProgram[32] = {
    0x06, 0xdd, 0xf6, 0xe1, 0xd7, 0x65, 0xa1, 0x93, 0xd9, 0xcb, 0xe1, 0x46, 0xce, 0xeb, 0x79, 0xac,
    0x1c, 0xb4, 0x85, 0xed, 0x5f, 0x5b, 0x37, 0x91, 0x3a, 0x8c, 0xf5, 0x85, 0x7e, 0xff, 0x00, 0xa9,
};
static const uint8_t msSolHostToken2022Program[32] = {
    0x06, 0xdd, 0xf6, 0xe1, 0xee, 0x75, 0x8f, 0xde, 0x18, 0x42, 0x5d, 0xbc, 0xe4, 0x6c, 0xcd, 0xda,
    0xb6, 0x1a, 0xfc, 0x4d, 0x83, 0xb9, 0x0d, 0x27, 0xfe, 0xbd, 0xf9, 0x28, 0xd8, 0xa1, 0x8b, 0xfc,
};
static const uint8_t msSolHostAssociatedProgram[32] = {
    0x8c, 0x97, 0x25, 0x8f, 0x4e, 0x24, 0x89, 0xf1, 0xbb, 0x3d, 0x10, 0x29, 0x14, 0x8e, 0x0d, 0x83,
    0x0b, 0x5a, 0x13, 0x99, 0xda, 0xff, 0x10, 0x84, 0x04, 0x8e, 0x7b, 0xd8, 0xdb, 0xe9, 0xf8, 0x59,
};

static const uint8_t msSolHostIncinerator[32] = {
    0x00, 0x33, 0x90, 0x72, 0x8d, 0x34, 0x11, 0x60, 0x79, 0xbd, 0xc9, 0x11, 0xbf, 0xff, 0x00, 0xdb,
    0xd4, 0x4d, 0x2e, 0xcd, 0xcc, 0xf7, 0x9c, 0xa6, 0xe1, 0x00, 0x38, 0xe1, 0x00, 0x00, 0x00, 0x00,
};

static int msSolHostIsTokenProgram(const uint8_t* key) {
    return memcmp(key, msSolHostTokenProgram, 32) == 0 || memcmp(key, msSolHostToken2022Program, 32) == 0;
}

static uint64_t msSolHostLoadU64(const uint8_t* at) {
    uint64_t value;
    memcpy(&value, at, 8);
    return value;
}

static void msSolHostStoreU64(uint8_t* at, uint64_t value) {
    memcpy(at, &value, 8);
}

static int msSolHostAnyByte(const uint8_t* bytes, uint64_t from, uint64_t to) {
    return msSolHostAnyByteIn((uint64_t)(uintptr_t)bytes, from, to) != 0;
}

uint64_t msSolHostTokenInvoke(uint64_t header);
uint64_t msSolHostAssociatedInvoke(uint64_t header);

static uint64_t msSolHostToken(const uint64_t* header) {
    return msSolHostTokenInvoke((uint64_t)(uintptr_t)header);
}

static uint64_t msSolHostAssociated(const uint64_t* header) {
    return msSolHostAssociatedInvoke((uint64_t)(uintptr_t)header);
}

static const uint8_t msSolHostSystemProgram[32] = {0};

static uint64_t msSolHostSystem(const uint64_t* header) {
    return msSolHostSystemInvoke((uint64_t)(uintptr_t)header);
}

static void msSolHostAdopt(msSolHostHeld* held) {
    const uint8_t* record = held->record;
    held->lamports = msSolHostLamports(record);
    held->length = msSolHostLoadU64(record + 80);
    memcpy(held->owner, record + 40, 32);
    held->data = (uint8_t*)realloc(held->data, (size_t)held->length + 1);
    if (held->data == NULL) abort();
    memcpy(held->data, record + 88, (size_t)held->length);
}

static void msSolHostHoldAccounts(void) {
    for (uint64_t index = 0; index < msSolHostState.accountCount; index++) {
        uint8_t* record = (uint8_t*)msSolHostAccounts[index];
        uint64_t earlier = 0;
        while (earlier < index && (uint8_t*)msSolHostAccounts[earlier] != record) earlier++;
        if (earlier < index) continue;
        msSolHostHeld* held = &msSolHostHolds[msSolHostHoldCount++];
        *held = (msSolHostHeld){.record = record, .index = index};
        msSolHostAdopt(held);
        held->startLamports = held->lamports;
        held->startLength = held->length;
    }
}

static msSolHostHeld* msSolHostHeldAt(const uint8_t* record) {
    for (uint64_t index = 0; index < msSolHostHoldCount; index++) {
        if (msSolHostHolds[index].record == record) return &msSolHostHolds[index];
    }
    return NULL;
}

static int msSolHostTakes(msSolHostHeld* held) {
    const uint8_t* record = held->record;
    const int writable = record[2] != 0;
    const int owned = memcmp(held->owner, (const void*)msSolHostContext()->programId, 32) == 0;
    const uint64_t lamports = msSolHostLamports(record);
    const uint64_t length = msSolHostLoadU64(record + 80);
    const char* refusal = NULL;
    if (lamports < held->lamports && !owned) {
        refusal = "ExternalAccountLamportSpend: the program spent lamports of an account it does not own";
    } else if (lamports != held->lamports && !writable) {
        refusal = "ReadonlyLamportChange: the program changed the lamports of an account the instruction does not pass writable";
    } else if (length != held->length || memcmp(record + 88, held->data, (size_t)length) != 0) {
        if (!writable) refusal = "ReadonlyDataModified: the program changed the data of an account the instruction does not pass writable";
        else if (!owned) refusal = "ExternalAccountDataModified: the program changed the data of an account it does not own";
    }
    if (refusal == NULL && memcmp(record + 40, held->owner, 32) != 0
        && (!owned || !writable || msSolHostAnyByte(record + 88, 0, length))) {
        refusal = "ModifiedProgramId: the program may give away only a writable account it owns whose bytes are all zero";
    }
    if (refusal == NULL) {
        msSolHostAdopt(held);
        return 1;
    }
    char text[sizeof(msSolHostFaultText)];
    snprintf(text, sizeof(text), "%s (account %llu)", refusal, (unsigned long long)held->index);
    msSolHostFault(MS_SOL_HOST_REFUSED, text);
    return 0;
}

static int msSolHostBalanced(void) {
    unsigned __int128 before = 0;
    unsigned __int128 now = 0;
    for (uint64_t index = 0; index < msSolHostHoldCount; index++) {
        before += msSolHostHolds[index].startLamports;
        now += msSolHostHolds[index].lamports;
    }
    if (before == now) return 1;
    msSolHostFault(MS_SOL_HOST_REFUSED,
        "UnbalancedInstruction: the lamports of the instruction's accounts do not sum to what they summed to before it");
    return 0;
}

static uint64_t msSolHostSignersRefused(uint64_t signers, uint64_t signerCount, uint64_t* recordedBytes) {
    const uint64_t programId = msSolHostContext()->programId;
    *recordedBytes = 0;
    if (signerCount > MS_SOL_MAX_SIGNERS) {
        msSolHostFault(MS_SOL_HOST_REFUSED, "ProgramFailedToComplete: sol_invoke_signed: Too many signers");
        return MS_SOL_HOST_REFUSED;
    }
    for (uint64_t signer = 0; signer < signerCount; signer++) {
        const uint64_t* entry = (const uint64_t*)(signers + signer * 16);
        if (entry[1] > MS_SOL_MAX_SEEDS) return 13ULL << 32;
        *recordedBytes += 8;
        for (uint64_t seed = 0; seed < entry[1]; seed++) {
            const uint64_t* slice = (const uint64_t*)(entry[0] + seed * 16);
            if (slice[1] > MS_SOL_MAX_SEED_LEN) {
                msSolHostFault(MS_SOL_HOST_REFUSED, "ProgramFailedToComplete: sol_invoke_signed: Could not create program address with signer seeds: " MS_SOL_HOST_SEED_TOO_LONG);
                return MS_SOL_HOST_REFUSED;
            }
            *recordedBytes += 8 + slice[1];
        }
        uint8_t address[32];
        if (!msSolHostDerive(entry[0], entry[1], NULL, programId, address)) {
            msSolHostFault(MS_SOL_HOST_REFUSED, "ProgramFailedToComplete: sol_invoke_signed: Could not create program address with signer seeds: Provided seeds do not result in a valid address");
            return MS_SOL_HOST_REFUSED;
        }
    }
    return 0;
}

static int msSolHostSignsFor(const uint8_t* key, uint64_t signers, uint64_t signerCount) {
    const uint64_t programId = msSolHostContext()->programId;
    for (uint64_t signer = 0; signer < signerCount; signer++) {
        const uint64_t* entry = (const uint64_t*)(signers + signer * 16);
        uint8_t address[32];
        if (msSolHostDerive(entry[0], entry[1], NULL, programId, address) && memcmp(address, key, 32) == 0) return 1;
    }
    return 0;
}

static int msSolHostPrivilegesHeld(const uint64_t* header, uint64_t signers, uint64_t signerCount) {
    for (uint64_t index = 0; index < header[2]; index++) {
        const uint8_t* meta = (const uint8_t*)(header[1] + index * 16);
        const uint8_t* record = (const uint8_t*)(*(const uint64_t*)meta - 8);
        if (meta[8] != 0 && record[2] == 0) {
            msSolHostFault(MS_SOL_HOST_REFUSED, "PrivilegeEscalation: sol_invoke_signed: an account's writable privilege escalated: the instruction did not pass it writable");
            return 0;
        }
        if (meta[9] != 0 && record[1] == 0 && !msSolHostSignsFor(record + 8, signers, signerCount)) {
            msSolHostFault(MS_SOL_HOST_REFUSED, "PrivilegeEscalation: sol_invoke_signed: an account's signer privilege escalated: it did not sign and no signer seeds derive it");
            return 0;
        }
    }
    return 1;
}

static void msSolHostRecordSigners(uint8_t* out, uint64_t signers, uint64_t signerCount) {
    for (uint64_t signer = 0; signer < signerCount; signer++) {
        const uint64_t* entry = (const uint64_t*)(signers + signer * 16);
        memcpy(out, &entry[1], 8);
        out += 8;
        for (uint64_t seed = 0; seed < entry[1]; seed++) {
            const uint64_t* slice = (const uint64_t*)(entry[0] + seed * 16);
            memcpy(out, &slice[1], 8);
            out += 8;
            if (slice[1] > 0) memcpy(out, (const void*)slice[0], (size_t)slice[1]);
            out += slice[1];
        }
    }
}

static uint64_t msSolHostInvoked(const uint64_t* header, uint64_t signers, uint64_t signerCount) {
    uint64_t signerBytes;
    uint64_t refused = msSolHostSignersRefused(signers, signerCount, &signerBytes);
    if (refused != 0) return refused;
    if (!msSolHostPrivilegesHeld(header, signers, signerCount)) return MS_SOL_HOST_MISSING_REQUIRED_SIGNATURE;
    for (uint64_t index = 0; index < header[2]; index++) {
        msSolHostHeld* held = msSolHostHeldAt(msSolHostRecordOf(header, index));
        if (held != NULL && !msSolHostTakes(held)) return MS_SOL_HOST_REFUSED;
    }
    if (!msSolHostBalanced()) return MS_SOL_HOST_REFUSED;
    msSolHostInvocation* grown = (msSolHostInvocation*)realloc(msSolHostInvocations,
        (size_t)(msSolHostInvocationCount + 1) * sizeof(msSolHostInvocation));
    if (grown == NULL) abort();
    msSolHostInvocations = grown;
    msSolHostInvocation* record = &msSolHostInvocations[msSolHostInvocationCount++];
    memcpy(record->program, (const void*)header[0], 32);
    record->metaCount = header[2];
    record->metas = (uint8_t*)malloc((size_t)(header[2] * 34 + 1));
    if (record->metas == NULL) abort();
    for (uint64_t index = 0; index < header[2]; index++) {
        const uint8_t* meta = (const uint8_t*)(header[1] + index * 16);
        memcpy(record->metas + index * 34, (const void*)*(const uint64_t*)meta, 32);
        record->metas[index * 34 + 32] = meta[8];
        record->metas[index * 34 + 33] = meta[9];
    }
    record->dataLength = header[4];
    record->data = (uint8_t*)malloc((size_t)header[4] + 1);
    if (record->data == NULL) abort();
    if (header[4] > 0) memcpy(record->data, (const void*)header[3], (size_t)header[4]);
    record->signerCount = signerCount;
    record->signerSeeds = (uint8_t*)malloc((size_t)signerBytes + 1);
    if (record->signerSeeds == NULL) abort();
    msSolHostRecordSigners(record->signerSeeds, signers, signerCount);
    msSolHostClearReturnData();
    const uint8_t* callee = (const uint8_t*)header[0];
    uint64_t status = 0;
    if (memcmp(callee, msSolHostSystemProgram, 32) == 0) status = msSolHostSystem(header);
    else if (msSolHostIsTokenProgram(callee)) status = msSolHostToken(header);
    else if (memcmp(callee, msSolHostAssociatedProgram, 32) == 0) status = msSolHostAssociated(header);
    for (uint64_t index = 0; status == 0 && index < header[2]; index++) {
        msSolHostHeld* held = msSolHostHeldAt(msSolHostRecordOf(header, index));
        if (held != NULL) msSolHostAdopt(held);
    }
    return status;
}

uint64_t msSolHostInvokeSigned(uint64_t instruction, uint64_t accountInfos, uint64_t accountInfoCount, uint64_t signers, uint64_t signerCount) {
    (void)accountInfos;
    (void)accountInfoCount;
    if (msSolHostFaultCode != 0) return msSolHostFaultCode;
    uint64_t status = msSolHostInvoked((const uint64_t*)instruction, signers, signerCount);
    if (status != 0) msSolHostFault(status, "");
    return status;
}

static int msSolHostPaysRent(uint64_t lamports, uint64_t length) {
    return lamports != 0 && lamports < msSolHostRentExempt(length);
}

void msSolHostLeave(void) {
    if (msSolHostFaultCode != 0 || msSolHostState.result != 0) return;
    for (uint64_t index = 0; index < msSolHostHoldCount; index++) {
        if (!msSolHostTakes(&msSolHostHolds[index])) return;
    }
    if (!msSolHostBalanced()) return;
    for (uint64_t index = 0; index < msSolHostHoldCount; index++) {
        const msSolHostHeld* held = &msSolHostHolds[index];
        uint8_t* record = held->record;
        if (record[2] == 0 || memcmp(record + 8, msSolHostIncinerator, 32) == 0) continue;
        if (held->lamports == 0) {
            msSolHostStoreU64(record + 80, 0);
            memset(record + 40, 0, 32);
            continue;
        }
        if (!msSolHostPaysRent(held->lamports, held->length)) continue;
        if (msSolHostPaysRent(held->startLamports, held->startLength) && held->length == held->startLength
            && held->lamports <= held->startLamports) continue;
        char text[sizeof(msSolHostFaultText)];
        snprintf(text, sizeof(text),
            "InsufficientFundsForRent: account %llu ends the transaction with %llu lamports, its %llu bytes are rent exempt from %llu",
            (unsigned long long)held->index, (unsigned long long)held->lamports, (unsigned long long)held->length,
            (unsigned long long)msSolHostRentExempt(held->length));
        msSolHostFault(MS_SOL_HOST_REFUSED, text);
        return;
    }
}

void msSolHostSetReturnData(const uint8_t* data, int64_t length) {
    msSolHostSetReturnDataAt((uint64_t)data, (uint64_t)length);
}

#endif
