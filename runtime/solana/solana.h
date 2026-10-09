#ifndef MS_SOLANA_H
#define MS_SOLANA_H

#include <stdint.h>
#include <stdbool.h>

#include "runtime/core/string.h"

#define MS_SOL_ACCOUNT_HEADER_SIZE 88ULL
#define MS_SOL_MAX_PERMITTED_DATA_INCREASE 10240ULL
#define MS_SOL_DUPLICATE_MARKER 0xFF

#ifndef MS_SOL_MAX_ACCOUNTS
#define MS_SOL_MAX_ACCOUNTS 255
#endif
_Static_assert(MS_SOL_MAX_ACCOUNTS >= 1 && MS_SOL_MAX_ACCOUNTS <= 255,
    "MS_SOL_MAX_ACCOUNTS is 1 to 255: the runtime numbers an instruction's accounts with one byte");

#ifdef MSOS_SOLANA

static inline msSolanaContext* msSolContext(void) {
    return msSolanaCurrentContext();
}

static inline uint64_t msSolAlloc(uint64_t size) {
    return (uint64_t)msArenaAlloc((size_t)size);
}

#else

typedef struct {
    uint64_t input;
    uint64_t result;
    uint64_t arenaPosition;
    uint64_t accountCount;
    uint64_t accountTable;
    uint64_t instructionData;
    uint64_t instructionDataLength;
    uint64_t programId;
    bool err;
    void* currException;
} msSolanaContext;

msSolanaContext* msSolHostContext(void);
uint64_t msSolHostAlloc(uint64_t size);
uint64_t msSolHostInput(uint64_t size);
void msSolHostEnter(uint64_t input);
uint64_t msSolHostResult(void);
uint64_t msSolHostFaultCodeOf(void);
msString msSolHostFaultMessage(void);
uint64_t msSolHostLogTotal(void);
msString msSolHostLogAt(uint64_t index);
uint64_t msSolHostInvocationTotal(void);
uint64_t msSolHostInvocationAt(uint64_t index);
void msSolHostSetClock(uint64_t slot, uint64_t epochStart, uint64_t epoch, uint64_t leaderEpoch, uint64_t unixTime);
void msSolHostLog(uint64_t address, uint64_t length);
void msSolHostLog64(uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e);
void msSolHostLogPubkey(uint64_t address);
void msSolHostLogData(uint64_t address, uint64_t length);
void msSolHostLogComputeUnits(void);
uint64_t msSolHostRemainingComputeUnits(void);
void msSolHostCopy(uint64_t destination, uint64_t source, uint64_t length);
void msSolHostFill(uint64_t destination, uint8_t value, uint64_t length);
int32_t msSolHostCompare(uint64_t left, uint64_t right, uint64_t length);
uint64_t msSolHostSha256(uint64_t slices, uint64_t count, uint64_t out);
uint64_t msSolHostCurveValidatePoint(uint64_t curve, uint64_t point, uint64_t result);
uint64_t msSolHostCreateProgramAddress(uint64_t seeds, uint64_t count, uint64_t programId, uint64_t out);
uint64_t msSolHostTryFindProgramAddress(uint64_t seeds, uint64_t count, uint64_t programId, uint64_t out, uint64_t bumpOut);
uint64_t msSolHostInvokeSigned(uint64_t instruction, uint64_t accountInfos, uint64_t accountInfoCount, uint64_t signers, uint64_t signerCount);
uint64_t msSolHostGetClock(uint64_t out);
uint64_t msSolHostGetRent(uint64_t out);
void msSolHostSetReturnData(const uint8_t* data, int64_t length);
uint64_t msSolHostGetReturnData(uint64_t data, uint64_t length, uint64_t programId);

static inline msSolanaContext* msSolContext(void) {
    return msSolHostContext();
}

static inline uint64_t msSolAlloc(uint64_t size) {
    return msSolHostAlloc(size);
}

#endif

static inline const uint8_t* msSolNextRecord(const uint8_t* cursor) {
    if (cursor[0] != MS_SOL_DUPLICATE_MARKER) return cursor + 8;
    uint64_t dataLength = *(const uint64_t*)(cursor + 80);
    cursor += MS_SOL_ACCOUNT_HEADER_SIZE + dataLength + MS_SOL_MAX_PERMITTED_DATA_INCREASE;
    cursor = (const uint8_t*)(((uint64_t)cursor + 7) & ~(uint64_t)7);
    return cursor + 8;
}

static inline const uint8_t* msSolParseAccounts(uint64_t* table) {
    msSolanaContext* context = msSolContext();
    const uint8_t* cursor = (const uint8_t*)context->input;
    uint64_t count = *(const uint64_t*)cursor;
    cursor += 8;
    uint64_t kept = count < MS_SOL_MAX_ACCOUNTS ? count : MS_SOL_MAX_ACCOUNTS;
    for (uint64_t index = 0; index < kept; index++) {
        const uint8_t marker = cursor[0];
        if (marker != MS_SOL_DUPLICATE_MARKER) {
            table[index] = table[marker];
            cursor += 8;
        } else {
            table[index] = (uint64_t)cursor;
            const uint64_t dataLength = *(const uint64_t*)(cursor + 80);
            cursor += MS_SOL_ACCOUNT_HEADER_SIZE + dataLength + MS_SOL_MAX_PERMITTED_DATA_INCREASE;
            cursor = (const uint8_t*)(((uint64_t)cursor + 7) & ~(uint64_t)7);
            cursor += 8;
        }
    }
    context->accountCount = kept;
    context->accountTable = (uint64_t)table;
    return cursor;
}

static inline __attribute__((noinline)) void msSolParse(uint64_t* table) {
    msSolanaContext* context = msSolContext();
    const uint8_t* cursor = msSolParseAccounts(table);
    const uint64_t count = *(const uint64_t*)context->input;
    for (uint64_t index = context->accountCount; index < count; index++) cursor = msSolNextRecord(cursor);
    context->instructionDataLength = *(const uint64_t*)cursor;
    cursor += 8;
    context->instructionData = (uint64_t)cursor;
    cursor += context->instructionDataLength;
    context->programId = (uint64_t)cursor;
}

static inline __attribute__((always_inline)) void msSolStart(uint64_t* table, const uint8_t* instructionData) {
    msSolParseAccounts(table);
    msSolanaContext* context = msSolContext();
    context->instructionData = (uint64_t)instructionData;
    context->instructionDataLength = *(const uint64_t*)(instructionData - 8);
    context->programId = (uint64_t)instructionData + context->instructionDataLength;
}

static inline uint64_t msSolAccountCount(void) {
    return msSolContext()->accountCount;
}

static inline uint64_t msSolAccountAt(uint64_t index) {
    msSolanaContext* context = msSolContext();
    return index < context->accountCount ? ((const uint64_t*)context->accountTable)[index] : 0;
}

static inline uint64_t msSolInstructionData(void) {
    return msSolContext()->instructionData;
}

static inline uint64_t msSolInstructionDataLength(void) {
    return msSolContext()->instructionDataLength;
}

static inline uint64_t msSolProgramId(void) {
    return msSolContext()->programId;
}

static inline void msSolSetResult(uint64_t code) {
    msSolContext()->result = code;
}

static inline void* msSolPointer(uint64_t address) {
    return (void*)(uintptr_t)address;
}

static inline uint8_t msSolLoadU8(uint64_t address) {
    return *(const uint8_t*)address;
}

static inline uint16_t msSolLoadU16(uint64_t address) {
    uint16_t value;
    __builtin_memcpy(&value, (const void*)address, 2);
    return value;
}

static inline uint32_t msSolLoadU32(uint64_t address) {
    uint32_t value;
    __builtin_memcpy(&value, (const void*)address, 4);
    return value;
}

static inline uint64_t msSolLoadU64(uint64_t address) {
    uint64_t value;
    __builtin_memcpy(&value, (const void*)address, 8);
    return value;
}

static inline void msSolStoreU8(uint64_t address, uint8_t value) {
    *(uint8_t*)address = value;
}

static inline void msSolStoreU16(uint64_t address, uint16_t value) {
    __builtin_memcpy((void*)address, &value, 2);
}

static inline void msSolStoreU32(uint64_t address, uint32_t value) {
    __builtin_memcpy((void*)address, &value, 4);
}

static inline void msSolStoreU64(uint64_t address, uint64_t value) {
    __builtin_memcpy((void*)address, &value, 8);
}

#ifdef MSOS_SOLANA

static inline void msSolCopy(uint64_t destination, uint64_t source, uint64_t length) {
    ((void (*)(uint64_t, uint64_t, uint64_t))0x717cc4a3ULL)(destination, source, length);
}

static inline void msSolFill(uint64_t destination, uint8_t value, uint64_t length) {
    ((void (*)(uint64_t, uint64_t, uint64_t))0x3770fb22ULL)(destination, (uint64_t)value, length);
}

static inline int32_t msSolCompare(uint64_t left, uint64_t right, uint64_t length) {
    int32_t result = 0;
    ((void (*)(uint64_t, uint64_t, uint64_t, int32_t*))0x5fdcde31ULL)(left, right, length, &result);
    return result;
}

static inline void msSolLog(uint64_t address, uint64_t length) {
    ((void (*)(uint64_t, uint64_t))0x207559bdULL)(address, length);
}

static inline void msSolLog64(uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e) {
    ((void (*)(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t))0x5c2a3178ULL)(a, b, c, d, e);
}

static inline void msSolLogPubkey(uint64_t address) {
    ((void (*)(uint64_t))0x7ef088caULL)(address);
}

static inline void msSolLogData(uint64_t address, uint64_t length) {
    uint64_t slice[2] = { address, length };
    ((void (*)(uint64_t, uint64_t))0x7317b434ULL)((uint64_t)slice, 1);
}

static inline void msSolLogComputeUnits(void) {
    ((void (*)(void))0x52ba5096ULL)();
}

static inline uint64_t msSolRemainingComputeUnits(void) {
    return ((uint64_t (*)(void))0xedef5aeeULL)();
}

static inline uint64_t msSolCreateProgramAddress(uint64_t seeds, uint64_t seedCount, uint64_t programId, uint64_t out) {
    return ((uint64_t (*)(uint64_t, uint64_t, uint64_t, uint64_t))0x9377323cULL)(seeds, seedCount, programId, out);
}

static inline uint64_t msSolTryFindProgramAddress(uint64_t seeds, uint64_t seedCount, uint64_t programId, uint64_t out, uint64_t bump) {
    return ((uint64_t (*)(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t))0x48504a38ULL)(seeds, seedCount, programId, out, bump);
}

static inline uint64_t msSolInvokeSigned(uint64_t instruction, uint64_t accountInfos, uint64_t accountInfoCount, uint64_t signers, uint64_t signerCount) {
    return ((uint64_t (*)(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t))0xa22b9c85ULL)(instruction, accountInfos, accountInfoCount, signers, signerCount);
}

static inline uint64_t msSolGetClock(uint64_t out) {
    return ((uint64_t (*)(uint64_t))0xd56b5fe9ULL)(out);
}

static inline uint64_t msSolGetRent(uint64_t out) {
    static const uint8_t rentId[32] = {
        0x06, 0xa7, 0xd5, 0x17, 0x19, 0x2c, 0x5c, 0x51, 0x21, 0x8c, 0xc9, 0x4c, 0x3d, 0x4a, 0xf1, 0x7f,
        0x58, 0xda, 0xee, 0x08, 0x9b, 0xa1, 0xfd, 0x44, 0xe3, 0xdb, 0xd9, 0x8a, 0x00, 0x00, 0x00, 0x00 };
    return ((uint64_t (*)(uint64_t, uint64_t, uint64_t, uint64_t))0x13c1b505ULL)((uint64_t)rentId, out, 0, 16);
}

static inline uint64_t msSolSha256(uint64_t slices, uint64_t count, uint64_t out) {
    return ((uint64_t (*)(uint64_t, uint64_t, uint64_t))0x11f49d86ULL)(slices, count, out);
}

static inline uint64_t msSolCurveValidatePoint(uint64_t curve, uint64_t point, uint64_t result) {
    return ((uint64_t (*)(uint64_t, uint64_t, uint64_t))0xaa2607caULL)(curve, point, result);
}

static inline void msSolSetReturnData(const uint8_t* data, int64_t length) {
    ((void (*)(uint64_t, uint64_t))0xa226d3ebULL)((uint64_t)data, (uint64_t)length);
}

static inline uint64_t msSolGetReturnData(uint64_t data, uint64_t length, uint64_t programId) {
    return ((uint64_t (*)(uint64_t, uint64_t, uint64_t))0x5d2245e4ULL)(data, length, programId);
}

#else

static inline void msSolCopy(uint64_t destination, uint64_t source, uint64_t length) {
    msSolHostCopy(destination, source, length);
}

static inline void msSolFill(uint64_t destination, uint8_t value, uint64_t length) {
    msSolHostFill(destination, value, length);
}

static inline int32_t msSolCompare(uint64_t left, uint64_t right, uint64_t length) {
    return msSolHostCompare(left, right, length);
}

static inline void msSolLog(uint64_t address, uint64_t length) {
    msSolHostLog(address, length);
}

static inline void msSolLog64(uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e) {
    msSolHostLog64(a, b, c, d, e);
}

static inline void msSolLogPubkey(uint64_t address) {
    msSolHostLogPubkey(address);
}

static inline void msSolLogData(uint64_t address, uint64_t length) {
    msSolHostLogData(address, length);
}

static inline void msSolLogComputeUnits(void) {
    msSolHostLogComputeUnits();
}

static inline uint64_t msSolRemainingComputeUnits(void) {
    return msSolHostRemainingComputeUnits();
}

static inline uint64_t msSolCreateProgramAddress(uint64_t seeds, uint64_t seedCount, uint64_t programId, uint64_t out) {
    return msSolHostCreateProgramAddress(seeds, seedCount, programId, out);
}

static inline uint64_t msSolTryFindProgramAddress(uint64_t seeds, uint64_t seedCount, uint64_t programId, uint64_t out, uint64_t bump) {
    return msSolHostTryFindProgramAddress(seeds, seedCount, programId, out, bump);
}

static inline uint64_t msSolInvokeSigned(uint64_t instruction, uint64_t accountInfos, uint64_t accountInfoCount, uint64_t signers, uint64_t signerCount) {
    return msSolHostInvokeSigned(instruction, accountInfos, accountInfoCount, signers, signerCount);
}

static inline uint64_t msSolGetClock(uint64_t out) {
    return msSolHostGetClock(out);
}

static inline uint64_t msSolGetRent(uint64_t out) {
    return msSolHostGetRent(out);
}

static inline uint64_t msSolSha256(uint64_t slices, uint64_t count, uint64_t out) {
    return msSolHostSha256(slices, count, out);
}

static inline uint64_t msSolCurveValidatePoint(uint64_t curve, uint64_t point, uint64_t result) {
    return msSolHostCurveValidatePoint(curve, point, result);
}

static inline void msSolSetReturnData(const uint8_t* data, int64_t length) {
    msSolHostSetReturnData(data, length);
}

static inline uint64_t msSolGetReturnData(uint64_t data, uint64_t length, uint64_t programId) {
    return msSolHostGetReturnData(data, length, programId);
}

#endif

typedef struct {
    uint64_t address;
    uint64_t length;
} msSolSeed;

#define MS_SOL_MAX_SEEDS 16
#define MS_SOL_MAX_SEED_LENGTH 32

static inline uint64_t msSolSeedStage(msSolSeed* input, uint64_t table, uint64_t count, uint64_t limit) {
    if (count > limit) return 0;
    for (uint64_t index = 0; index < count; index++) {
        const uint64_t length = msSolLoadU64(table + index * 16 + 8);
        if (length > MS_SOL_MAX_SEED_LENGTH) return 0;
        input[index].address = msSolLoadU64(table + index * 16);
        input[index].length = length;
    }
    return 1;
}

static inline uint64_t msSolSeedTail(msSolSeed* input, uint64_t at, uint64_t program) {
    static const char tag[] = "ProgramDerivedAddress";
    input[at].address = program;
    input[at].length = 32;
    input[at + 1].address = (uint64_t)(uintptr_t)tag;
    input[at + 1].length = sizeof(tag) - 1;
    return at + 2;
}

/* The sha256 of the seeds, the bump when it is at most 255, the program and the tag: 0 with the hash in out, 2 when
   there are too many seeds or one is over 32 bytes. No curve check. */
static inline uint64_t msSolHashAddress(uint64_t table, uint64_t count, uint64_t bump, uint64_t program, uint64_t out) {
    msSolSeed input[MS_SOL_MAX_SEEDS + 2];
    uint8_t last = (uint8_t)bump;
    const uint64_t withBump = bump <= 255;
    if (!msSolSeedStage(input, table, count, MS_SOL_MAX_SEEDS - withBump)) return 2;
    if (withBump) {
        input[count].address = (uint64_t)(uintptr_t)&last;
        input[count].length = 1;
    }
    const uint64_t total = msSolSeedTail(input, count + withBump, program);
    msSolSha256((uint64_t)(uintptr_t)input, total, out);
    return 0;
}

/* 0: off the curve, a valid address; 1: on the curve; 2: as msSolHashAddress.
   A bump above 255 means the seeds carry none. */
static inline uint64_t msSolDeriveAddress(uint64_t table, uint64_t count, uint64_t bump, uint64_t program, uint64_t out) {
    if (msSolHashAddress(table, count, bump, program, out) != 0) return 2;
    return msSolCurveValidatePoint(0, out, 0) != 0 ? 0 : 1;
}

/* The canonical bump of seeds that carry none: 0 and the bump through bumpOut, 1 when every bump is on the curve, 2 as above. */
static inline uint64_t msSolFindAddress(uint64_t table, uint64_t count, uint64_t program, uint64_t out, uint64_t bumpOut) {
    msSolSeed input[MS_SOL_MAX_SEEDS + 2];
    uint8_t bump = 255;
    if (!msSolSeedStage(input, table, count, MS_SOL_MAX_SEEDS - 1)) return 2;
    input[count].address = (uint64_t)(uintptr_t)&bump;
    input[count].length = 1;
    const uint64_t total = msSolSeedTail(input, count + 1, program);
    for (uint64_t attempt = 0; attempt < 255; attempt++) {
        bump = (uint8_t)(255 - attempt);
        msSolSha256((uint64_t)(uintptr_t)input, total, out);
        if (msSolCurveValidatePoint(0, out, 0) != 0) {
            msSolStoreU8(bumpOut, bump);
            return 0;
        }
    }
    return 1;
}

/* msSolFindAddress for a key the caller names: 0 and its bump when it is the canonical address, 1 when it is not.
   The matching hash skips the curve check, because a key on the curve cannot sign: the runtime refuses the first
   CPI signed with these seeds. Every bump above it is still checked, so a non-canonical key is refused. */
static inline uint64_t msSolFindExpectedAddress(uint64_t table, uint64_t count, uint64_t program, uint64_t expected, uint64_t bumpOut) {
    msSolSeed input[MS_SOL_MAX_SEEDS + 2];
    uint8_t hash[32];
    const uint64_t out = (uint64_t)(uintptr_t)hash;
    uint8_t bump = 255;
    if (!msSolSeedStage(input, table, count, MS_SOL_MAX_SEEDS - 1)) return 2;
    input[count].address = (uint64_t)(uintptr_t)&bump;
    input[count].length = 1;
    const uint64_t total = msSolSeedTail(input, count + 1, program);
    for (uint64_t attempt = 0; attempt < 255; attempt++) {
        bump = (uint8_t)(255 - attempt);
        msSolSha256((uint64_t)(uintptr_t)input, total, out);
        if (msSolLoadU64(out) == msSolLoadU64(expected) && msSolLoadU64(out + 8) == msSolLoadU64(expected + 8) &&
            msSolLoadU64(out + 16) == msSolLoadU64(expected + 16) && msSolLoadU64(out + 24) == msSolLoadU64(expected + 24)) {
            msSolStoreU8(bumpOut, bump);
            return 0;
        }
        if (msSolCurveValidatePoint(0, out, 0) != 0) return 1;
    }
    return 1;
}

#define MS_SOL_MAX_CPI_ACCOUNTS 64

typedef struct {
    uint64_t key;
    uint64_t lamports;
    uint64_t dataLength;
    uint64_t data;
    uint64_t owner;
    uint64_t rentEpoch;
    uint8_t signer;
    uint8_t writable;
    uint8_t executable;
} msSolCpiAccount;

typedef struct {
    uint64_t program;
    uint64_t accounts;
    uint64_t accountCount;
    uint64_t data;
    uint64_t dataLength;
} msSolCpiInstruction;

/* count is at most MS_SOL_MAX_CPI_ACCOUNTS; metas are 16-byte InstructionAccount records. */
static __attribute__((noinline)) uint64_t msSolInvokeMetas(uint64_t program, uint64_t metas, uint64_t count, uint64_t data, uint64_t length, uint64_t signers, uint64_t signerCount) {
    msSolCpiAccount infos[MS_SOL_MAX_CPI_ACCOUNTS];
    for (uint64_t index = 0; index < count; index++) {
        const uint64_t key = msSolLoadU64(metas + index * 16);
        const uint64_t record = key - 8;
        infos[index].key = key;
        infos[index].lamports = record + 72;
        infos[index].dataLength = msSolLoadU64(record + 80);
        infos[index].data = record + 88;
        infos[index].owner = record + 40;
        infos[index].rentEpoch = 0;
        infos[index].signer = msSolLoadU8(record + 1);
        infos[index].writable = msSolLoadU8(record + 2);
        infos[index].executable = msSolLoadU8(record + 3);
    }
    msSolCpiInstruction instruction = { program, metas, count, data, length };
    return msSolInvokeSigned((uint64_t)(uintptr_t)&instruction, (uint64_t)(uintptr_t)infos, count, signers, signerCount);
}

static inline uint64_t msSolStringAddress(msString text) {
    return text.p == (msStrPayload*)0 ? 0 : (uint64_t)text.p->data;
}

static inline uint64_t msSolStringLength(msString text) {
    return (uint64_t)text.len;
}

static inline uint64_t msSolSpanAddress(const void* data, int64_t length) {
    (void)length;
    return (uint64_t)(uintptr_t)data;
}

#endif
