#ifndef MS_SOLANA_H
#define MS_SOLANA_H

#include <stdint.h>
#include <stdbool.h>

#ifndef MSOS_SOLANA
#error "runtime/solana/solana.h builds only with --os=solana"
#endif

#include "runtime/core/string.h"

#define MS_SOL_ACCOUNT_HEADER_SIZE 88ULL
#define MS_SOL_MAX_PERMITTED_DATA_INCREASE 10240ULL
#define MS_SOL_DUPLICATE_MARKER 0xFF

static inline void msSolParse(void) {
    msSolanaContext* context = msSolanaCurrentContext();
    if (context->accountTable != 0) return;
    const uint8_t* cursor = (const uint8_t*)context->input;
    uint64_t count = *(const uint64_t*)cursor;
    cursor += 8;
    uint64_t* table = (uint64_t*)msArenaAlloc((size_t)((count == 0 ? 1 : count) * 8));
    for (uint64_t index = 0; index < count; index++) {
        if (cursor[0] == MS_SOL_DUPLICATE_MARKER) {
            uint64_t dataLength = *(const uint64_t*)(cursor + 80);
            table[index] = (uint64_t)cursor;
            cursor += MS_SOL_ACCOUNT_HEADER_SIZE + dataLength + MS_SOL_MAX_PERMITTED_DATA_INCREASE;
            cursor = (const uint8_t*)(((uint64_t)cursor + 7) & ~(uint64_t)7);
            cursor += 8;
        } else {
            table[index] = table[cursor[0]];
            cursor += 8;
        }
    }
    context->accountCount = count;
    context->accountTable = (uint64_t)table;
    context->instructionDataLength = *(const uint64_t*)cursor;
    cursor += 8;
    context->instructionData = (uint64_t)cursor;
    cursor += context->instructionDataLength;
    context->programId = (uint64_t)cursor;
}

static inline uint64_t msSolAccountCount(void) {
    msSolParse();
    return msSolanaCurrentContext()->accountCount;
}

static inline uint64_t msSolAccountAt(uint64_t index) {
    msSolParse();
    msSolanaContext* context = msSolanaCurrentContext();
    return index < context->accountCount ? ((const uint64_t*)context->accountTable)[index] : 0;
}

static inline uint64_t msSolInstructionData(void) {
    msSolParse();
    return msSolanaCurrentContext()->instructionData;
}

static inline uint64_t msSolInstructionDataLength(void) {
    msSolParse();
    return msSolanaCurrentContext()->instructionDataLength;
}

static inline uint64_t msSolProgramId(void) {
    msSolParse();
    return msSolanaCurrentContext()->programId;
}

static inline uint64_t msSolAlloc(uint64_t size) {
    return (uint64_t)msArenaAlloc((size_t)size);
}

static inline void msSolSetResult(uint64_t code) {
    msSolanaCurrentContext()->result = code;
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

static inline void msSolLogComputeUnits(void) {
    ((void (*)(void))0x52ba5096ULL)();
}

static inline uint64_t msSolRemainingComputeUnits(void) {
    return ((uint64_t (*)(void))0xedef5aeeULL)();
}

static inline uint64_t msSolStringAddress(msString text) {
    return text.p == (msStrPayload*)0 ? 0 : (uint64_t)text.p->data;
}

static inline uint64_t msSolStringLength(msString text) {
    return (uint64_t)text.len;
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
    return ((uint64_t (*)(uint64_t))0xbf7188f6ULL)(out);
}

static inline uint64_t msSolSha256(uint64_t slices, uint64_t count, uint64_t out) {
    return ((uint64_t (*)(uint64_t, uint64_t, uint64_t))0x11f49d86ULL)(slices, count, out);
}

static inline void msSolSetReturnData(uint64_t address, uint64_t length) {
    ((void (*)(uint64_t, uint64_t))0xa226d3ebULL)(address, length);
}

#endif
