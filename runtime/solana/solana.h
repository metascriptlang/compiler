#ifndef MS_SOLANA_H
#define MS_SOLANA_H

#include <stdint.h>
#include <stdbool.h>

#include "runtime/core/string.h"

#define MS_SOL_ACCOUNT_HEADER_SIZE 88ULL
#define MS_SOL_MAX_PERMITTED_DATA_INCREASE 10240ULL
#define MS_SOL_DUPLICATE_MARKER 0xFF
#define MS_SOL_BORROW_OFFSET 4
#define MS_SOL_CLAIMED_RECORD 1
#define MS_SOL_DUPLICATED_RECORD 2
#define MS_SOL_PEELED_ACCOUNTS 4

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

static inline uint64_t msSolScratch(uint64_t size) {
    if (size > MS_SOLANA_ARENA_SIZE - msSolanaCurrentContext()->arenaUsed) return 0;
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
    uint64_t programId;
    bool err;
    void* currException;
    uint64_t rent[3];
} msSolanaContext;

msSolanaContext* msSolHostContext(void);
uint64_t msSolHostAlloc(uint64_t size);
uint64_t msSolHostScratch(uint64_t size);
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
uint64_t msSolHostRentReadTotal(void);
void msSolHostSetReturnData(const uint8_t* data, int64_t length);
uint64_t msSolHostGetReturnData(uint64_t data, uint64_t length, uint64_t programId);

static inline msSolanaContext* msSolContext(void) {
    return msSolHostContext();
}

static inline uint64_t msSolAlloc(uint64_t size) {
    return msSolHostAlloc(size);
}

static inline uint64_t msSolScratch(uint64_t size) {
    return msSolHostScratch(size);
}

#endif

static inline const uint8_t* msSolNextRecord(const uint8_t* cursor) {
    if (cursor[0] != MS_SOL_DUPLICATE_MARKER) return cursor + 8;
    uint64_t dataLength = *(const uint64_t*)(cursor + 80);
    cursor += MS_SOL_ACCOUNT_HEADER_SIZE + dataLength + MS_SOL_MAX_PERMITTED_DATA_INCREASE;
    cursor = (const uint8_t*)(((uint64_t)cursor + 7) & ~(uint64_t)7);
    return cursor + 8;
}

static inline const uint8_t* msSolPastRecord(const uint8_t* record) {
    return (const uint8_t*)(((uint64_t)record + *(const uint64_t*)(record + 80) +
        (MS_SOL_ACCOUNT_HEADER_SIZE + MS_SOL_MAX_PERMITTED_DATA_INCREASE + 15)) & ~(uint64_t)7);
}

/* Returns the last record it read, not the one after it: the instruction data comes from the runtime, so the
   walk past the final account would be paid for nothing. */
static inline __attribute__((always_inline)) const uint8_t* msSolParseAccounts(const uint8_t* input, uint64_t* table) {
    msSolanaContext* context = msSolContext();
    const uint8_t* cursor = input + 8;
    const uint64_t count = *(const uint64_t*)input;
#if MS_SOL_MAX_ACCOUNTS == 255
    /* The loader refuses more than 255 accounts before the program runs (agave serialization.rs), so the default
       table's bound is one branch; a clamp measured 4 instructions on every instruction. */
    if (count > MS_SOL_MAX_ACCOUNTS) __builtin_trap();
    const uint64_t kept = count;
#else
    const uint64_t kept = count < MS_SOL_MAX_ACCOUNTS ? count : MS_SOL_MAX_ACCOUNTS;
#endif
    *table = (uint64_t)cursor;
    if (kept > 1) {
        uint64_t* slot = table + MS_SOL_PEELED_ACCOUNTS;
        cursor = msSolPastRecord(cursor);
        for (uint64_t index = 1; index < MS_SOL_PEELED_ACCOUNTS; index++) {
            if (cursor[0] != MS_SOL_DUPLICATE_MARKER) {
                slot = table + index;
                break;
            }
            table[index] = (uint64_t)cursor;
            if (kept == index + 1) goto parsed;
            cursor = msSolPastRecord(cursor);
        }
        uint64_t* end = table + kept;
        for (;;) {
            const uint8_t marker = cursor[0];
            if (marker == MS_SOL_DUPLICATE_MARKER) {
                *slot++ = (uint64_t)cursor;
                if (slot == end) break;
                cursor = msSolPastRecord(cursor);
            } else {
                *slot++ = table[marker];
                ((uint8_t*)table[marker])[MS_SOL_BORROW_OFFSET] = MS_SOL_DUPLICATED_RECORD;
                if (slot == end) break;
                cursor += 8;
            }
        }
    }
parsed:
    context->accountCount = kept;
    context->accountTable = (uint64_t)table;
    return cursor;
}

static inline __attribute__((noinline)) const uint8_t* msSolInstructionDataAfter(const uint8_t* input, const uint8_t* last) {
    const uint64_t count = *(const uint64_t*)input;
    const uint64_t kept = msSolContext()->accountCount;
    for (uint64_t index = kept == 0 ? 0 : kept - 1; index < count; index++) last = msSolNextRecord(last);
    return last + 8;
}

#ifndef MSOS_SOLANA
static inline __attribute__((noinline)) void msSolParse(uint64_t* table) {
    msSolanaContext* context = msSolContext();
    const uint8_t* input = (const uint8_t*)context->input;
    const uint8_t* instructionData = msSolInstructionDataAfter(input, msSolParseAccounts(input, table));
    context->instructionData = (uint64_t)instructionData;
    context->programId = (uint64_t)instructionData + *(const uint64_t*)(instructionData - 8);
}
#endif

static inline __attribute__((always_inline)) void msSolStart(const uint8_t* input, uint64_t* table, const uint8_t* instructionData) {
    const uint8_t* last = msSolParseAccounts(input, table);
    if (!instructionData) instructionData = msSolInstructionDataAfter(input, last);
    msSolContext()->instructionData = (uint64_t)instructionData;
}

static inline uint64_t msSolAccountTable(void) {
    return msSolContext()->accountTable;
}

/* A callee can grow an account without this program counting it, so the room for an account's data is read
   from where the next record starts in the input: the length the instruction began with plus the runtime's
   reserve, never from a running count. */
static inline __attribute__((noinline)) uint64_t msSolDataRoom(uint64_t record) {
    const msSolanaContext* context = msSolContext();
    const uint64_t* table = (const uint64_t*)context->accountTable;
    const uint64_t count = context->accountCount;
    uint64_t index = 0;
    while (index < count && table[index] != record) index++;
    if (index == count) return 0;
    uint64_t next = index + 1;
    while (next < count && table[next] <= record) next++;
    uint64_t end = context->instructionData - 8;
    if (next < count) end = table[next];
#ifdef MSOS_SOLANA
    else if (*(const uint64_t*)MS_SOLANA_INPUT_START != count) return 0;
#else
    else if (*(const uint64_t*)context->input != count) return 0;
#endif
    return end - 8 * (next - index) - (record + MS_SOL_ACCOUNT_HEADER_SIZE);
}

static inline uint64_t msSolAccountCount(void) {
    return msSolContext()->accountCount;
}

static inline uint64_t msSolAccountAt(uint64_t index) {
    msSolanaContext* context = msSolContext();
    if (index >= context->accountCount) return 0;
    const uint64_t address = ((const uint64_t*)context->accountTable)[index];
    if (address == 0) __builtin_unreachable();
    return address;
}

static inline uint64_t msSolInstructionData(void) {
    return msSolContext()->instructionData;
}

static inline uint64_t msSolInstructionDataLength(void) {
    return *(const uint64_t*)(msSolContext()->instructionData - 8);
}

static inline uint64_t msSolProgramId(void) {
#ifdef MSOS_SOLANA
    const uint64_t data = msSolContext()->instructionData;
    return data + *(const uint64_t*)(data - 8);
#else
    return msSolContext()->programId;
#endif
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

static inline void msSolClaimRecord(uint64_t address) {
    ((uint8_t*)address)[MS_SOL_BORROW_OFFSET] = MS_SOL_CLAIMED_RECORD;
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

/* The rent sysvar is read once per instruction: the context starts zeroed for every instruction and a nonzero
   lamports-per-byte-year marks the words as read. */
static inline uint64_t msSolRentAddress(void) {
    msSolanaContext* context = msSolContext();
    if (context->rent[0] == 0) msSolGetRent((uint64_t)(uintptr_t)context->rent);
    return (uint64_t)(uintptr_t)context->rent;
}

typedef struct {
    uint64_t address;
    uint64_t length;
} msSolSeed;

#define MS_SOL_MAX_SEEDS 16
#define MS_SOL_MAX_SEED_LENGTH 32

#define MS_SOL_STAGED static inline __attribute__((always_inline))

/* Staging is inlined into the caller, where the seed count and every literal length are constants: the checks fold
   away and each slice is written once, into the array the hash reads. */
MS_SOL_STAGED uint64_t msSolSeedStage(msSolSeed* input, uint64_t table, uint64_t count, uint64_t limit) {
    const msSolSeed* seeds = (const msSolSeed*)(uintptr_t)table;
    if (count > limit) return 0;
    for (uint64_t index = 0; index < count; index++) {
        const uint64_t length = seeds[index].length;
        if (length > MS_SOL_MAX_SEED_LENGTH) return 0;
        input[index].address = seeds[index].address;
        input[index].length = length;
    }
    return 1;
}

MS_SOL_STAGED uint64_t msSolSeedTail(msSolSeed* input, uint64_t at, uint64_t program) {
    static const char tag[] = "ProgramDerivedAddress";
    input[at].address = program;
    input[at].length = 32;
    input[at + 1].address = (uint64_t)(uintptr_t)tag;
    input[at + 1].length = sizeof(tag) - 1;
    return at + 2;
}

/* The bump's slice, one byte at `bump`, then the program and the tag. */
MS_SOL_STAGED void msSolSeedSlot(msSolSeed* input, uint64_t at, uint64_t bump, uint64_t program) {
    input[at].address = bump;
    input[at].length = 1;
    msSolSeedTail(input, at + 1, program);
}

/* A table the caller built with three free slices after its seeds is staged where it is, with nothing copied.
   Answers the number of seeds, or MS_SOL_MAX_SEEDS for a table that cannot be hashed. */
MS_SOL_STAGED uint64_t msSolSeedStageInPlace(uint64_t table, uint64_t count, uint64_t bump, uint64_t program) {
    msSolSeed* input = (msSolSeed*)(uintptr_t)table;
    const uint64_t used = count - 3;
    if (count < 3 || !msSolSeedStage(input, table, used, MS_SOL_MAX_SEEDS - 1)) return MS_SOL_MAX_SEEDS;
    msSolSeedSlot(input, used, bump, program);
    return used;
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

static inline bool msSolKeyIs(uint64_t key, uint64_t expected) {
    return msSolLoadU64(key) == msSolLoadU64(expected) && msSolLoadU64(key + 8) == msSolLoadU64(expected + 8) &&
        msSolLoadU64(key + 16) == msSolLoadU64(expected + 16) && msSolLoadU64(key + 24) == msSolLoadU64(expected + 24);
}

/* The bump walks below take staged slices and count the byte at bumpOut, which the bump's slice names, down from
   255: it holds the bump they stop at. */
static __attribute__((noinline)) uint64_t msSolWalkAny(msSolSeed* input, uint64_t at, uint64_t out, uint64_t bumpOut) {
    for (uint64_t counter = 255; counter > 0; counter--) {
        msSolStoreU8(bumpOut, (uint8_t)counter);
        msSolSha256((uint64_t)(uintptr_t)input, at + 3, out);
        if (msSolCurveValidatePoint(0, out, 0) != 0) return 0;
    }
    return 1;
}

static inline uint64_t msSolWalkExpected(msSolSeed* input, uint64_t at, uint64_t expected, uint64_t bumpOut) {
    uint8_t hash[32];
    const uint64_t out = (uint64_t)(uintptr_t)hash;
    for (uint64_t counter = 255; counter > 0; counter--) {
        msSolStoreU8(bumpOut, (uint8_t)counter);
        msSolSha256((uint64_t)(uintptr_t)input, at + 3, out);
        if (msSolKeyIs(out, expected)) return 0;
        if (msSolCurveValidatePoint(0, out, 0) != 0) return 1;
    }
    return 1;
}

static inline uint64_t msSolWalkCanonical(msSolSeed* input, uint64_t at, uint64_t expected, uint64_t bumpOut) {
    uint8_t hash[32];
    const uint64_t out = (uint64_t)(uintptr_t)hash;
    for (uint64_t counter = 255; counter > 0; counter--) {
        msSolStoreU8(bumpOut, (uint8_t)counter);
        msSolSha256((uint64_t)(uintptr_t)input, at + 3, out);
        if (msSolCurveValidatePoint(0, out, 0) != 0) return msSolKeyIs(out, expected) ? 0 : 3;
    }
    return 1;
}

/* The canonical bump of seeds that carry none: 0 and the bump through bumpOut, 1 when every bump is on the curve, 2 as above. */
MS_SOL_STAGED uint64_t msSolFindAddress(uint64_t table, uint64_t count, uint64_t program, uint64_t out, uint64_t bumpOut) {
    msSolSeed input[MS_SOL_MAX_SEEDS + 2];
    if (!msSolSeedStage(input, table, count, MS_SOL_MAX_SEEDS - 1)) return 2;
    msSolSeedSlot(input, count, bumpOut, program);
    return msSolWalkAny(input, count, out, bumpOut);
}

/* msSolFindAddress for a key the caller names: 0 and its bump when it is the canonical address, 1 when it is not.
   The matching hash skips the curve check, because a key on the curve cannot sign: the runtime refuses the first
   CPI signed with these seeds. Every bump above it is still checked, so a non-canonical key is refused. */
MS_SOL_STAGED uint64_t msSolFindExpectedAddress(uint64_t table, uint64_t count, uint64_t program, uint64_t expected, uint64_t bumpOut) {
    msSolSeed input[MS_SOL_MAX_SEEDS + 2];
    if (!msSolSeedStage(input, table, count, MS_SOL_MAX_SEEDS - 1)) return 2;
    msSolSeedSlot(input, count, bumpOut, program);
    return msSolWalkExpected(input, count, expected, bumpOut);
}

/* msSolFindAddress for a key the caller names, curve-checked at the matching bump too: 0 when the canonical address is
   expected, 3 when it is not, 1 when every bump is on the curve, 2 as msSolHashAddress. */
MS_SOL_STAGED uint64_t msSolFindCanonicalAddress(uint64_t table, uint64_t count, uint64_t program, uint64_t expected, uint64_t bumpOut) {
    msSolSeed input[MS_SOL_MAX_SEEDS + 2];
    if (!msSolSeedStage(input, table, count, MS_SOL_MAX_SEEDS - 1)) return 2;
    msSolSeedSlot(input, count, bumpOut, program);
    return msSolWalkCanonical(input, count, expected, bumpOut);
}

/* The finds and the hash of a table msSolSeedStageInPlace staged, which answered `used`: 2 when it refused the table. */
MS_SOL_STAGED uint64_t msSolFindExpectedStaged(uint64_t table, uint64_t used, uint64_t expected) {
    msSolSeed* input = (msSolSeed*)(uintptr_t)table;
    if (used >= MS_SOL_MAX_SEEDS) return 2;
    return msSolWalkExpected(input, used, expected, input[used].address);
}

MS_SOL_STAGED uint64_t msSolFindCanonicalStaged(uint64_t table, uint64_t used, uint64_t expected) {
    msSolSeed* input = (msSolSeed*)(uintptr_t)table;
    if (used >= MS_SOL_MAX_SEEDS) return 2;
    return msSolWalkCanonical(input, used, expected, input[used].address);
}

/* 0 when the sha256 of the seeds and `bump` is `expected`, 3 when it is not. No curve check. */
MS_SOL_STAGED uint64_t msSolHashIsStaged(uint64_t table, uint64_t used, uint64_t bump, uint64_t expected) {
    msSolSeed* input = (msSolSeed*)(uintptr_t)table;
    uint8_t hash[32];
    if (used >= MS_SOL_MAX_SEEDS) return 2;
    msSolStoreU8(input[used].address, (uint8_t)bump);
    msSolSha256(table, used + 3, (uint64_t)(uintptr_t)hash);
    return msSolKeyIs((uint64_t)(uintptr_t)hash, expected) ? 0 : 3;
}

#define MS_SOL_MAX_CPI_ACCOUNTS 64

typedef struct {
    uint64_t key;
    uint64_t lamports;
    uint64_t dataLength;
    uint64_t data;
    uint64_t owner;
    uint64_t rentEpoch;
    /* SolAccountInfo's is_signer, is_writable, executable and one byte of its padding: bytes 1 to 4 of the
       account record, in that order. */
    uint32_t recordFlags;
} msSolCpiAccount;
_Static_assert(__builtin_offsetof(msSolCpiAccount, recordFlags) == 48 && sizeof(msSolCpiAccount) == 56,
    "msSolCpiAccount is the runtime's SolAccountInfo");

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
        infos[index].recordFlags = msSolLoadU32(record + 1);
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
