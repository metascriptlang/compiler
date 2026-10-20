#ifndef MS_SOLANA_H
#define MS_SOLANA_H

#include <stdint.h>
#include <stdbool.h>

#include "runtime/core/string.h"

#define MS_SOL_ACCOUNT_HEADER_SIZE 88ULL
#define MS_SOL_BORROW_OFFSET 4
#define MS_SOL_CLAIMED_RECORD 1

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

uint64_t msSolHostContext(void);
uint64_t msSolHostAlloc(uint64_t size);
uint64_t msSolHostScratch(uint64_t size);
uint64_t msSolHostInput(uint64_t size);
void msSolHostEnter(uint64_t input);
void msSolHostLeave(void);
uint64_t msSolHostResult(void);
void msSolHostRaise(uint64_t code, msString text);
uint64_t msSolHostFaultCodeOf(void);
void msSolHostClearFault(void);
msString msSolHostFaultMessage(void);
uint64_t msSolHostLogTotal(void);
msString msSolHostLogAt(uint64_t index);
uint64_t msSolHostInvocationTotal(void);
uint64_t msSolHostInvocationAt(uint64_t index);
void msSolHostSetClock(uint64_t slot, uint64_t epochStart, uint64_t epoch, uint64_t leaderEpoch, uint64_t unixTime);
void msSolHostSetSysvarStatus(uint64_t status);
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
void msSolHostSetReturnDataAt(uint64_t data, uint64_t length);
uint64_t msSolHostGetReturnData(uint64_t data, uint64_t length, uint64_t programId);

static inline msSolanaContext* msSolContext(void) {
    return (msSolanaContext*)(uintptr_t)msSolHostContext();
}

static inline uint64_t msSolAlloc(uint64_t size) {
    return msSolHostAlloc(size);
}

static inline uint64_t msSolScratch(uint64_t size) {
    return msSolHostScratch(size);
}

#endif

#ifdef MSOS_SOLANA
/* std/solana/simulatorContext.ms parses the input, through std/solana/kernel.cms. */
uint64_t msSolEntryAccounts(uint64_t input, uint64_t table, uint64_t limit);
uint64_t msSolEntryInstructionData(uint64_t input);

static inline void msSolHostRaise(uint64_t code, msString text) {
    (void)code;
    (void)text;
    __builtin_trap();
}

static inline __attribute__((always_inline)) void msSolStart(const uint8_t* input, uint64_t* table, const uint8_t* instructionData) {
    if (!instructionData) instructionData = (const uint8_t*)msSolEntryInstructionData((uint64_t)input);
    msSolanaContext* context = msSolContext();
    context->accountCount = msSolEntryAccounts((uint64_t)input, (uint64_t)table, MS_SOL_MAX_ACCOUNTS);
    context->accountTable = (uint64_t)table;
    context->instructionData = (uint64_t)instructionData;
}
#endif

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

static inline uint64_t msSolAccountSlot(uint64_t index) {
    return ((const uint64_t*)msSolContext()->accountTable)[index];
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

static inline uint64_t msSolResult(void) {
    return msSolContext()->result;
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
    msSolHostSetReturnDataAt((uint64_t)(uintptr_t)data, (uint64_t)length);
}

static inline uint64_t msSolGetReturnData(uint64_t data, uint64_t length, uint64_t programId) {
    return msSolHostGetReturnData(data, length, programId);
}

#endif

/* The rent sysvar is read once per instruction: the context starts zeroed for every instruction and a nonzero
   lamports-per-byte-year marks the words as read. */
static inline uint64_t msSolRentAddress(void) {
    msSolanaContext* context = msSolContext();
    if (context->rent[0] == 0 && msSolGetRent((uint64_t)(uintptr_t)context->rent) != 0) return 0;
    return (uint64_t)(uintptr_t)context->rent;
}

/* The logic is std/solana/simulatorSeeds.ms and simulatorMetas.ms; C only holds their frames, which are not zeroed. */
uint64_t msSolDeriveAddressAt(uint64_t input, uint64_t last, uint64_t table, uint64_t count, uint64_t bump, uint64_t program, uint64_t out);
uint64_t msSolFindAddressAt(uint64_t input, uint64_t table, uint64_t count, uint64_t program, uint64_t out, uint64_t bumpOut);
uint64_t msSolFindExpectedAddressAt(uint64_t input, uint64_t hash, uint64_t table, uint64_t count, uint64_t program, uint64_t expected, uint64_t bumpOut);
uint64_t msSolFindCanonicalAddressAt(uint64_t input, uint64_t hash, uint64_t table, uint64_t count, uint64_t program, uint64_t expected, uint64_t bumpOut);
uint64_t msSolSeedStageInPlaceAt(uint64_t table, uint64_t count, uint64_t bump, uint64_t program);
uint64_t msSolFindExpectedStagedAt(uint64_t hash, uint64_t table, uint64_t used, uint64_t expected);
uint64_t msSolFindCanonicalStagedAt(uint64_t hash, uint64_t table, uint64_t used, uint64_t expected);
uint64_t msSolHashIsStagedAt(uint64_t hash, uint64_t table, uint64_t used, uint64_t bump, uint64_t expected);
uint64_t msSolInvokeMetasAt(uint64_t infos, uint64_t header, uint64_t program, uint64_t metas, uint64_t count, uint64_t data,
    uint64_t length, uint64_t signers, uint64_t signerCount);

#define MS_SOL_FLAT static inline __attribute__((always_inline, flatten))

MS_SOL_FLAT uint64_t msSolSeedStageInPlace(uint64_t table, uint64_t count, uint64_t bump, uint64_t program) {
    return msSolSeedStageInPlaceAt(table, count, bump, program);
}

MS_SOL_FLAT uint64_t msSolFindExpectedStaged(uint64_t table, uint64_t used, uint64_t expected) {
    uint8_t hash[32];
    return msSolFindExpectedStagedAt((uint64_t)(uintptr_t)hash, table, used, expected);
}

MS_SOL_FLAT uint64_t msSolFindCanonicalStaged(uint64_t table, uint64_t used, uint64_t expected) {
    uint8_t hash[32];
    return msSolFindCanonicalStagedAt((uint64_t)(uintptr_t)hash, table, used, expected);
}

MS_SOL_FLAT uint64_t msSolHashIsStaged(uint64_t table, uint64_t used, uint64_t bump, uint64_t expected) {
    uint8_t hash[32];
    return msSolHashIsStagedAt((uint64_t)(uintptr_t)hash, table, used, bump, expected);
}

static inline uint64_t msSolDeriveAddress(uint64_t table, uint64_t count, uint64_t bump, uint64_t program, uint64_t out) {
    uint64_t words[36];
    uint8_t last;
    return msSolDeriveAddressAt((uint64_t)(uintptr_t)words, (uint64_t)(uintptr_t)&last, table, count, bump, program, out);
}

static inline __attribute__((always_inline)) uint64_t msSolFindAddress(uint64_t table, uint64_t count, uint64_t program, uint64_t out, uint64_t bumpOut) {
    uint64_t words[36];
    return msSolFindAddressAt((uint64_t)(uintptr_t)words, table, count, program, out, bumpOut);
}

static inline __attribute__((always_inline)) uint64_t msSolFindExpectedAddress(uint64_t table, uint64_t count, uint64_t program, uint64_t expected, uint64_t bumpOut) {
    uint64_t words[36];
    uint8_t hash[32];
    return msSolFindExpectedAddressAt((uint64_t)(uintptr_t)words, (uint64_t)(uintptr_t)hash, table, count, program, expected, bumpOut);
}

static inline __attribute__((always_inline)) uint64_t msSolFindCanonicalAddress(uint64_t table, uint64_t count, uint64_t program, uint64_t expected, uint64_t bumpOut) {
    uint64_t words[36];
    uint8_t hash[32];
    return msSolFindCanonicalAddressAt((uint64_t)(uintptr_t)words, (uint64_t)(uintptr_t)hash, table, count, program, expected, bumpOut);
}

static __attribute__((noinline)) uint64_t msSolInvokeMetas(uint64_t program, uint64_t metas, uint64_t count, uint64_t data, uint64_t length, uint64_t signers, uint64_t signerCount) {
    uint64_t infos[64 * 7];
    uint64_t header[5];
    return msSolInvokeMetasAt((uint64_t)(uintptr_t)infos, (uint64_t)(uintptr_t)header, program, metas, count, data, length, signers, signerCount);
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
