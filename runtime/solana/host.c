#ifndef MSOS_SOLANA

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "runtime/solana/solana.h"

#define MS_SOL_HOST_HEAP_SIZE (32 * 1024)
#define MS_SOL_HOST_COMPUTE_BUDGET 200000ULL
#define MS_SOL_MAX_SEEDS 16
#define MS_SOL_MAX_SEED_LEN 32
#define MS_SOL_MAX_RETURN_DATA 1024

typedef struct {
    uint8_t program[32];
    uint64_t metaCount;
    uint8_t* metas;
    uint64_t dataLength;
    uint8_t* data;
    uint64_t signerCount;
} msSolHostInvocation;

static _Alignas(16) uint8_t msSolHostHeap[MS_SOL_HOST_HEAP_SIZE];
static const uint64_t msSolHostEmptyInput[6];
static msSolanaContext msSolHostState;
static uint8_t* msSolHostInputBuffer;
static uint64_t msSolHostFaultCode;
static char msSolHostFaultText[160];
static char** msSolHostLogLines;
static uint64_t msSolHostLogCount;
static msSolHostInvocation* msSolHostInvocations;
static uint64_t msSolHostInvocationCount;
static uint8_t msSolHostReturnData[MS_SOL_MAX_RETURN_DATA];
static uint64_t msSolHostReturnLength;
static uint8_t msSolHostReturnProgram[32];
static uint64_t msSolHostClock[5];

msSolanaContext* msSolHostContext(void) {
    if (msSolHostState.input == 0) {
        msSolHostState.input = (uint64_t)msSolHostEmptyInput;
        msSolHostState.arenaPosition = sizeof(msSolanaContext);
    }
    return &msSolHostState;
}

static void msSolHostFault(uint64_t code, const char* text) {
    if (msSolHostFaultCode != 0) return;
    msSolHostFaultCode = code;
    snprintf(msSolHostFaultText, sizeof(msSolHostFaultText), "%s", text);
}

uint64_t msSolHostAlloc(uint64_t size) {
    msSolanaContext* context = msSolHostContext();
    size = (size + 7) & ~(uint64_t)7;
    if (context->arenaPosition + size > MS_SOL_HOST_HEAP_SIZE) {
        fprintf(stderr, "std/solana host: the 32 KiB program heap is exhausted (asked %llu more bytes at %llu)\n",
            (unsigned long long)size, (unsigned long long)context->arenaPosition);
        abort();
    }
    uint64_t address = (uint64_t)(msSolHostHeap + context->arenaPosition);
    context->arenaPosition += size;
    return address;
}

static void msSolHostForget(void) {
    for (uint64_t index = 0; index < msSolHostLogCount; index++) free(msSolHostLogLines[index]);
    free(msSolHostLogLines);
    msSolHostLogLines = NULL;
    msSolHostLogCount = 0;
    for (uint64_t index = 0; index < msSolHostInvocationCount; index++) {
        free(msSolHostInvocations[index].metas);
        free(msSolHostInvocations[index].data);
    }
    free(msSolHostInvocations);
    msSolHostInvocations = NULL;
    msSolHostInvocationCount = 0;
}

void msSolHostEnter(uint64_t input) {
    msSolHostForget();
    memset(msSolHostHeap, 0, sizeof(msSolHostHeap));
    memset(&msSolHostState, 0, sizeof(msSolHostState));
    msSolHostState.input = input == 0 ? (uint64_t)msSolHostEmptyInput : input;
    msSolHostState.arenaPosition = sizeof(msSolanaContext);
    msSolHostFaultCode = 0;
    msSolHostFaultText[0] = 0;
    msSolHostReturnLength = 0;
    memset(msSolHostReturnProgram, 0, sizeof(msSolHostReturnProgram));
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
uint64_t msSolHostLogTotal(void) { return msSolHostLogCount; }

msString msSolHostLogAt(uint64_t index) {
    if (index >= msSolHostLogCount) return msStringNew("", 0);
    return msStringNew(msSolHostLogLines[index], (int64_t)strlen(msSolHostLogLines[index]));
}

uint64_t msSolHostInvocationTotal(void) { return msSolHostInvocationCount; }

uint64_t msSolHostInvocationAt(uint64_t index) {
    return index < msSolHostInvocationCount ? (uint64_t)&msSolHostInvocations[index] : 0;
}

void msSolHostSetClock(uint64_t slot, uint64_t epochStart, uint64_t epoch, uint64_t leaderEpoch, uint64_t unixTime) {
    msSolHostClock[0] = slot;
    msSolHostClock[1] = epochStart;
    msSolHostClock[2] = epoch;
    msSolHostClock[3] = leaderEpoch;
    msSolHostClock[4] = unixTime;
}

static void msSolHostRecordLog(const char* text) {
    char** grown = (char**)realloc(msSolHostLogLines, (size_t)(msSolHostLogCount + 1) * sizeof(char*));
    if (grown == NULL) abort();
    msSolHostLogLines = grown;
    size_t length = strlen(text);
    char* copy = (char*)malloc(length + 1);
    if (copy == NULL) abort();
    memcpy(copy, text, length + 1);
    msSolHostLogLines[msSolHostLogCount++] = copy;
}

static void msSolHostBase58(const uint8_t* key, char* out) {
    static const char alphabet[] = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
    uint8_t digits[64];
    size_t digitCount = 0;
    for (size_t index = 0; index < 32; index++) {
        uint32_t carry = key[index];
        for (size_t digit = 0; digit < digitCount; digit++) {
            carry += (uint32_t)digits[digit] << 8;
            digits[digit] = (uint8_t)(carry % 58);
            carry /= 58;
        }
        while (carry > 0) {
            digits[digitCount++] = (uint8_t)(carry % 58);
            carry /= 58;
        }
    }
    size_t length = 0;
    for (size_t index = 0; index < 32 && key[index] == 0; index++) out[length++] = '1';
    while (digitCount > 0) out[length++] = alphabet[digits[--digitCount]];
    out[length] = 0;
}

void msSolHostLog(uint64_t address, uint64_t length) {
    char* line = (char*)malloc((size_t)length + 14);
    if (line == NULL) abort();
    memcpy(line, "Program log: ", 13);
    memcpy(line + 13, (const void*)address, (size_t)length);
    line[13 + length] = 0;
    msSolHostRecordLog(line);
    free(line);
}

void msSolHostLog64(uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e) {
    char line[160];
    snprintf(line, sizeof(line), "Program log: 0x%llx, 0x%llx, 0x%llx, 0x%llx, 0x%llx",
        (unsigned long long)a, (unsigned long long)b, (unsigned long long)c, (unsigned long long)d, (unsigned long long)e);
    msSolHostRecordLog(line);
}

void msSolHostLogPubkey(uint64_t address) {
    char encoded[64];
    char line[96];
    msSolHostBase58((const uint8_t*)address, encoded);
    snprintf(line, sizeof(line), "Program log: %s", encoded);
    msSolHostRecordLog(line);
}

void msSolHostLogData(uint64_t address, uint64_t length) {
    static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const uint8_t* bytes = (const uint8_t*)address;
    size_t encodedLength = (size_t)((length + 2) / 3 * 4);
    char* line = (char*)malloc(encodedLength + 15);
    if (line == NULL) abort();
    memcpy(line, "Program data: ", 14);
    size_t at = 14;
    for (uint64_t index = 0; index < length; index += 3) {
        uint32_t group = (uint32_t)bytes[index] << 16;
        if (index + 1 < length) group |= (uint32_t)bytes[index + 1] << 8;
        if (index + 2 < length) group |= bytes[index + 2];
        line[at++] = alphabet[(group >> 18) & 63];
        line[at++] = alphabet[(group >> 12) & 63];
        line[at++] = index + 1 < length ? alphabet[(group >> 6) & 63] : '=';
        line[at++] = index + 2 < length ? alphabet[group & 63] : '=';
    }
    line[at] = 0;
    msSolHostRecordLog(line);
    free(line);
}

void msSolHostLogComputeUnits(void) {
    char line[96];
    snprintf(line, sizeof(line), "Program consumption: %llu units remaining", (unsigned long long)MS_SOL_HOST_COMPUTE_BUDGET);
    msSolHostRecordLog(line);
}

uint64_t msSolHostRemainingComputeUnits(void) { return MS_SOL_HOST_COMPUTE_BUDGET; }

void msSolHostCopy(uint64_t destination, uint64_t source, uint64_t length) {
    if ((destination < source + length) && (source < destination + length)) {
        msSolHostFault(1, "sol_memcpy_: overlapping copy");
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

typedef struct {
    uint32_t state[8];
    uint8_t block[64];
    uint64_t length;
    size_t used;
} msSolHostSha;

static const uint32_t msSolHostShaK[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

static uint32_t msSolHostRotr(uint32_t value, int by) { return (value >> by) | (value << (32 - by)); }

static void msSolHostShaBlock(msSolHostSha* sha) {
    uint32_t w[64];
    for (int index = 0; index < 16; index++) {
        w[index] = ((uint32_t)sha->block[index * 4] << 24) | ((uint32_t)sha->block[index * 4 + 1] << 16) |
            ((uint32_t)sha->block[index * 4 + 2] << 8) | (uint32_t)sha->block[index * 4 + 3];
    }
    for (int index = 16; index < 64; index++) {
        uint32_t s0 = msSolHostRotr(w[index - 15], 7) ^ msSolHostRotr(w[index - 15], 18) ^ (w[index - 15] >> 3);
        uint32_t s1 = msSolHostRotr(w[index - 2], 17) ^ msSolHostRotr(w[index - 2], 19) ^ (w[index - 2] >> 10);
        w[index] = w[index - 16] + s0 + w[index - 7] + s1;
    }
    uint32_t a = sha->state[0], b = sha->state[1], c = sha->state[2], d = sha->state[3];
    uint32_t e = sha->state[4], f = sha->state[5], g = sha->state[6], h = sha->state[7];
    for (int index = 0; index < 64; index++) {
        uint32_t t1 = h + (msSolHostRotr(e, 6) ^ msSolHostRotr(e, 11) ^ msSolHostRotr(e, 25)) + ((e & f) ^ (~e & g)) +
            msSolHostShaK[index] + w[index];
        uint32_t t2 = (msSolHostRotr(a, 2) ^ msSolHostRotr(a, 13) ^ msSolHostRotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
        h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    sha->state[0] += a; sha->state[1] += b; sha->state[2] += c; sha->state[3] += d;
    sha->state[4] += e; sha->state[5] += f; sha->state[6] += g; sha->state[7] += h;
}

static void msSolHostShaStart(msSolHostSha* sha) {
    static const uint32_t start[8] = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    };
    memcpy(sha->state, start, sizeof(start));
    sha->length = 0;
    sha->used = 0;
}

static void msSolHostShaAdd(msSolHostSha* sha, const uint8_t* data, size_t length) {
    for (size_t index = 0; index < length; index++) {
        sha->block[sha->used++] = data[index];
        if (sha->used == 64) {
            msSolHostShaBlock(sha);
            sha->used = 0;
        }
    }
    sha->length += length;
}

static void msSolHostShaFinish(msSolHostSha* sha, uint8_t out[32]) {
    uint64_t bits = sha->length * 8;
    uint8_t pad = 0x80;
    msSolHostShaAdd(sha, &pad, 1);
    pad = 0;
    while (sha->used != 56) msSolHostShaAdd(sha, &pad, 1);
    for (int index = 7; index >= 0; index--) {
        uint8_t byte = (uint8_t)(bits >> (index * 8));
        msSolHostShaAdd(sha, &byte, 1);
    }
    for (int index = 0; index < 8; index++) {
        out[index * 4] = (uint8_t)(sha->state[index] >> 24);
        out[index * 4 + 1] = (uint8_t)(sha->state[index] >> 16);
        out[index * 4 + 2] = (uint8_t)(sha->state[index] >> 8);
        out[index * 4 + 3] = (uint8_t)sha->state[index];
    }
}

uint64_t msSolHostSha256(uint64_t slices, uint64_t count, uint64_t out) {
    msSolHostSha sha;
    msSolHostShaStart(&sha);
    for (uint64_t index = 0; index < count; index++) {
        const uint64_t* slice = (const uint64_t*)(slices + index * 16);
        msSolHostShaAdd(&sha, (const uint8_t*)slice[0], (size_t)slice[1]);
    }
    msSolHostShaFinish(&sha, (uint8_t*)out);
    return 0;
}

typedef uint64_t msSolHostFe[5];
typedef unsigned __int128 msSolHostWide;
#define MS_SOL_HOST_MASK51 ((1ULL << 51) - 1)

static void msSolHostFeCarry(msSolHostFe h) {
    for (int round = 0; round < 2; round++) {
        for (int index = 0; index < 4; index++) {
            h[index + 1] += h[index] >> 51;
            h[index] &= MS_SOL_HOST_MASK51;
        }
        h[0] += 19 * (h[4] >> 51);
        h[4] &= MS_SOL_HOST_MASK51;
    }
}

static void msSolHostFeMul(msSolHostFe h, const msSolHostFe f, const msSolHostFe g) {
    msSolHostWide t[5];
    uint64_t g19[5];
    for (int index = 0; index < 5; index++) g19[index] = g[index] * 19;
    t[0] = (msSolHostWide)f[0] * g[0] + (msSolHostWide)f[1] * g19[4] + (msSolHostWide)f[2] * g19[3] + (msSolHostWide)f[3] * g19[2] + (msSolHostWide)f[4] * g19[1];
    t[1] = (msSolHostWide)f[0] * g[1] + (msSolHostWide)f[1] * g[0] + (msSolHostWide)f[2] * g19[4] + (msSolHostWide)f[3] * g19[3] + (msSolHostWide)f[4] * g19[2];
    t[2] = (msSolHostWide)f[0] * g[2] + (msSolHostWide)f[1] * g[1] + (msSolHostWide)f[2] * g[0] + (msSolHostWide)f[3] * g19[4] + (msSolHostWide)f[4] * g19[3];
    t[3] = (msSolHostWide)f[0] * g[3] + (msSolHostWide)f[1] * g[2] + (msSolHostWide)f[2] * g[1] + (msSolHostWide)f[3] * g[0] + (msSolHostWide)f[4] * g19[4];
    t[4] = (msSolHostWide)f[0] * g[4] + (msSolHostWide)f[1] * g[3] + (msSolHostWide)f[2] * g[2] + (msSolHostWide)f[3] * g[1] + (msSolHostWide)f[4] * g[0];
    for (int index = 0; index < 4; index++) {
        t[index + 1] += t[index] >> 51;
        t[index] &= MS_SOL_HOST_MASK51;
    }
    t[0] += 19 * (t[4] >> 51);
    t[4] &= MS_SOL_HOST_MASK51;
    for (int index = 0; index < 5; index++) h[index] = (uint64_t)t[index];
    msSolHostFeCarry(h);
}

static void msSolHostFeCanonical(const msSolHostFe f, uint8_t out[32]) {
    msSolHostFe h;
    memcpy(h, f, sizeof(h));
    msSolHostFeCarry(h);
    uint64_t q = (h[0] + 19) >> 51;
    q = (h[1] + q) >> 51;
    q = (h[2] + q) >> 51;
    q = (h[3] + q) >> 51;
    q = (h[4] + q) >> 51;
    h[0] += 19 * q;
    for (int index = 0; index < 4; index++) {
        h[index + 1] += h[index] >> 51;
        h[index] &= MS_SOL_HOST_MASK51;
    }
    h[4] &= MS_SOL_HOST_MASK51;
    memset(out, 0, 32);
    for (int bit = 0; bit < 255; bit++) {
        if ((h[bit / 51] >> (bit % 51)) & 1) out[bit / 8] |= (uint8_t)(1 << (bit % 8));
    }
}

static int msSolHostIsOnCurve(const uint8_t point[32]) {
    static const msSolHostFe d = {929955233495203ULL, 466365720129213ULL, 1662059464998953ULL, 2033849074728123ULL, 1442794654840575ULL};
    static const msSolHostFe one = {1, 0, 0, 0, 0};
    msSolHostFe y = {0, 0, 0, 0, 0};
    for (int bit = 0; bit < 255; bit++) {
        if ((point[bit / 8] >> (bit % 8)) & 1) y[bit / 51] |= 1ULL << (bit % 51);
    }
    msSolHostFe y2, u, v, w, chi;
    msSolHostFeMul(y2, y, y);
    static const msSolHostFe twoP = {0xFFFFFFFFFFFDAULL, 0xFFFFFFFFFFFFEULL, 0xFFFFFFFFFFFFEULL, 0xFFFFFFFFFFFFEULL, 0xFFFFFFFFFFFFEULL};
    for (int index = 0; index < 5; index++) u[index] = y2[index] + twoP[index] - one[index];
    msSolHostFeCarry(u);
    msSolHostFeMul(v, d, y2);
    v[0] += 1;
    msSolHostFeCarry(v);
    msSolHostFeMul(w, u, v);
    memcpy(chi, one, sizeof(chi));
    for (int bit = 253; bit >= 0; bit--) {
        msSolHostFeMul(chi, chi, chi);
        if (bit != 0 && bit != 3) msSolHostFeMul(chi, chi, w);
    }
    uint8_t bytes[32];
    msSolHostFeCanonical(chi, bytes);
    int isZero = 1;
    for (int index = 0; index < 32; index++) isZero &= bytes[index] == 0;
    int isOne = bytes[0] == 1;
    for (int index = 1; index < 32; index++) isOne &= bytes[index] == 0;
    return isZero || isOne;
}

static int msSolHostSeedsFit(uint64_t seeds, uint64_t count) {
    if (count > MS_SOL_MAX_SEEDS) return 0;
    for (uint64_t index = 0; index < count; index++) {
        if (((const uint64_t*)(seeds + index * 16))[1] > MS_SOL_MAX_SEED_LEN) return 0;
    }
    return 1;
}

static int msSolHostDerive(uint64_t seeds, uint64_t count, const uint8_t* bump, uint64_t programId, uint8_t out[32]) {
    if (count + (bump != NULL ? 1 : 0) > MS_SOL_MAX_SEEDS) return 0;
    msSolHostSha sha;
    msSolHostShaStart(&sha);
    for (uint64_t index = 0; index < count; index++) {
        const uint64_t* slice = (const uint64_t*)(seeds + index * 16);
        msSolHostShaAdd(&sha, (const uint8_t*)slice[0], (size_t)slice[1]);
    }
    if (bump != NULL) msSolHostShaAdd(&sha, bump, 1);
    msSolHostShaAdd(&sha, (const uint8_t*)programId, 32);
    msSolHostShaAdd(&sha, (const uint8_t*)"ProgramDerivedAddress", 21);
    msSolHostShaFinish(&sha, out);
    return !msSolHostIsOnCurve(out);
}

uint64_t msSolHostCreateProgramAddress(uint64_t seeds, uint64_t count, uint64_t programId, uint64_t out) {
    if (!msSolHostSeedsFit(seeds, count)) {
        msSolHostFault(2, "sol_create_program_address: more than 16 seeds or a seed over 32 bytes");
        return 1;
    }
    uint8_t address[32];
    if (!msSolHostDerive(seeds, count, NULL, programId, address)) return 1;
    memcpy((void*)out, address, 32);
    return 0;
}

uint64_t msSolHostTryFindProgramAddress(uint64_t seeds, uint64_t count, uint64_t programId, uint64_t out, uint64_t bumpOut) {
    if (!msSolHostSeedsFit(seeds, count)) {
        msSolHostFault(2, "sol_try_find_program_address: more than 16 seeds or a seed over 32 bytes");
        return 1;
    }
    uint8_t bump = 255;
    for (int attempt = 0; attempt < 255; attempt++) {
        uint8_t address[32];
        if (msSolHostDerive(seeds, count, &bump, programId, address)) {
            memcpy((void*)out, address, 32);
            *(uint8_t*)bumpOut = bump;
            return 0;
        }
        bump--;
    }
    return 1;
}

static uint8_t* msSolHostRecordOf(const uint64_t* header, uint64_t index) {
    if (index >= header[2]) return NULL;
    const uint8_t* meta = (const uint8_t*)(header[1] + index * 16);
    return (uint8_t*)(*(const uint64_t*)meta - 8);
}

static uint64_t msSolHostLamports(const uint8_t* record) {
    uint64_t value;
    memcpy(&value, record + 72, 8);
    return value;
}

static void msSolHostSetLamports(uint8_t* record, uint64_t value) {
    memcpy(record + 72, &value, 8);
}

static uint64_t msSolHostResize(uint8_t* record, uint64_t space) {
    uint64_t length;
    memcpy(&length, record + 80, 8);
    int32_t delta;
    memcpy(&delta, record + 4, 4);
    int64_t next = (int64_t)delta + (int64_t)space - (int64_t)length;
    if (next > (int64_t)MS_SOL_MAX_PERMITTED_DATA_INCREASE) return 20ULL << 32;
    if (space > length) memset(record + 88 + length, 0, (size_t)(space - length));
    int32_t stored = (int32_t)next;
    memcpy(record + 4, &stored, 4);
    memcpy(record + 80, &space, 8);
    return 0;
}

static uint64_t msSolHostSystem(const uint64_t* header) {
    static const uint8_t systemProgram[32] = {0};
    if (memcmp((const void*)header[0], systemProgram, 32) != 0 || header[4] < 4) return 0;
    const uint8_t* data = (const uint8_t*)header[3];
    uint32_t tag;
    memcpy(&tag, data, 4);
    uint8_t* first = msSolHostRecordOf(header, 0);
    uint8_t* second = msSolHostRecordOf(header, 1);
    uint64_t amount = 0;
    if (header[4] >= 12) memcpy(&amount, data + 4, 8);
    switch (tag) {
    case 0: {
        if (first == NULL || second == NULL || header[4] < 52) return 3ULL << 32;
        if (msSolHostLamports(second) != 0) return 1ULL << 32;
        if (msSolHostLamports(first) < amount) return 1;
        uint64_t space;
        memcpy(&space, data + 12, 8);
        uint64_t status = msSolHostResize(second, space);
        if (status != 0) return status;
        msSolHostSetLamports(first, msSolHostLamports(first) - amount);
        msSolHostSetLamports(second, amount);
        memcpy(second + 40, data + 20, 32);
        return 0;
    }
    case 1:
        if (first == NULL || header[4] < 36) return 3ULL << 32;
        memcpy(first + 40, data + 4, 32);
        return 0;
    case 2:
        if (first == NULL || second == NULL) return 3ULL << 32;
        if (msSolHostLamports(first) < amount) return 1;
        msSolHostSetLamports(first, msSolHostLamports(first) - amount);
        msSolHostSetLamports(second, msSolHostLamports(second) + amount);
        return 0;
    case 8:
        if (first == NULL) return 3ULL << 32;
        return msSolHostResize(first, amount);
    default:
        return 0;
    }
}

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

static uint64_t msSolHostMoveTokens(uint8_t* source, const uint8_t* mintKey, uint8_t* destination, uint64_t amount) {
    uint8_t* from = source + 88;
    uint8_t* to = destination + 88;
    if (mintKey != NULL && (memcmp(from, mintKey, 32) != 0 || memcmp(to, mintKey, 32) != 0)) return 3;
    if (memcmp(from, to, 32) != 0) return 3;
    uint64_t held = msSolHostLoadU64(from + 64);
    if (held < amount) return 1;
    msSolHostStoreU64(from + 64, held - amount);
    msSolHostStoreU64(to + 64, msSolHostLoadU64(to + 64) + amount);
    return 0;
}

static uint64_t msSolHostToken(const uint64_t* header) {
    if (!msSolHostIsTokenProgram((const uint8_t*)header[0]) || header[4] < 1) return 0;
    const uint8_t* data = (const uint8_t*)header[3];
    uint8_t* first = msSolHostRecordOf(header, 0);
    uint8_t* second = msSolHostRecordOf(header, 1);
    uint8_t* third = msSolHostRecordOf(header, 2);
    uint8_t* fourth = msSolHostRecordOf(header, 3);
    uint64_t amount = header[4] >= 9 ? msSolHostLoadU64(data + 1) : 0;
    switch (data[0]) {
    case 3:
        if (first == NULL || second == NULL || third == NULL) return 11ULL << 32;
        if (memcmp(first + 88 + 32, third + 8, 32) != 0) return 4;
        return msSolHostMoveTokens(first, NULL, second, amount);
    case 7:
        if (first == NULL || second == NULL) return 11ULL << 32;
        if (memcmp(second + 88, first + 8, 32) != 0) return 3;
        msSolHostStoreU64(first + 88 + 36, msSolHostLoadU64(first + 88 + 36) + amount);
        msSolHostStoreU64(second + 88 + 64, msSolHostLoadU64(second + 88 + 64) + amount);
        return 0;
    case 9: {
        if (first == NULL || second == NULL || third == NULL) return 11ULL << 32;
        if (memcmp(first + 88 + 32, third + 8, 32) != 0) return 4;
        if (msSolHostLoadU64(first + 88 + 64) != 0) return 11;
        msSolHostSetLamports(second, msSolHostLamports(second) + msSolHostLamports(first));
        msSolHostSetLamports(first, 0);
        uint64_t length = msSolHostLoadU64(first + 80);
        memset(first + 88, 0, (size_t)length);
        msSolHostResize(first, 0);
        memset(first + 40, 0, 32);
        return 0;
    }
    case 12:
        if (first == NULL || second == NULL || third == NULL || fourth == NULL) return 11ULL << 32;
        if (header[4] < 10) return 12;
        if (memcmp(first + 88 + 32, fourth + 8, 32) != 0) return 4;
        if (second[88 + 44] != data[9]) return 18;
        return msSolHostMoveTokens(first, second + 8, third, amount);
    default:
        return 0;
    }
}

static uint64_t msSolHostAssociated(const uint64_t* header) {
    if (memcmp((const void*)header[0], msSolHostAssociatedProgram, 32) != 0) return 0;
    const uint8_t* data = (const uint8_t*)header[3];
    uint8_t* payer = msSolHostRecordOf(header, 0);
    uint8_t* associated = msSolHostRecordOf(header, 1);
    uint8_t* wallet = msSolHostRecordOf(header, 2);
    uint8_t* mint = msSolHostRecordOf(header, 3);
    uint8_t* program = msSolHostRecordOf(header, 5);
    if (payer == NULL || associated == NULL || wallet == NULL || mint == NULL || program == NULL) {
        return 11ULL << 32;
    }
    int idempotent = header[4] >= 1 && data[0] == 1;
    if (msSolHostLamports(associated) != 0) {
        if (idempotent && memcmp(associated + 40, program + 8, 32) == 0) return 0;
        return 1ULL << 32;
    }
    uint64_t rent = (165 + 128) * 3480 * 2;
    if (msSolHostLamports(payer) < rent) return 1;
    uint64_t status = msSolHostResize(associated, 165);
    if (status != 0) return status;
    msSolHostSetLamports(payer, msSolHostLamports(payer) - rent);
    msSolHostSetLamports(associated, rent);
    memcpy(associated + 40, program + 8, 32);
    memcpy(associated + 88, mint + 8, 32);
    memcpy(associated + 88 + 32, wallet + 8, 32);
    associated[88 + 108] = 1;
    return 0;
}

uint64_t msSolHostInvokeSigned(uint64_t instruction, uint64_t accountInfos, uint64_t accountInfoCount, uint64_t signers, uint64_t signerCount) {
    (void)accountInfos;
    (void)accountInfoCount;
    (void)signers;
    const uint64_t* header = (const uint64_t*)instruction;
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
    msSolHostReturnLength = 0;
    uint64_t status = msSolHostSystem(header);
    if (status == 0) status = msSolHostToken(header);
    if (status == 0) status = msSolHostAssociated(header);
    return status;
}

uint64_t msSolHostGetClock(uint64_t out) {
    memcpy((void*)out, msSolHostClock, sizeof(msSolHostClock));
    return 0;
}

uint64_t msSolHostGetRent(uint64_t out) {
    uint8_t* rent = (uint8_t*)out;
    uint64_t lamportsPerByteYear = 3480;
    uint64_t exemptionThreshold = 0x4000000000000000ULL;
    memset(rent, 0, 17);
    memcpy(rent, &lamportsPerByteYear, 8);
    memcpy(rent + 8, &exemptionThreshold, 8);
    rent[16] = 50;
    return 0;
}

void msSolHostSetReturnData(const uint8_t* data, int64_t length) {
    if (length < 0 || length > MS_SOL_MAX_RETURN_DATA) {
        msSolHostFault(3, "sol_set_return_data: more than 1024 bytes");
        return;
    }
    memcpy(msSolHostReturnData, data, (size_t)length);
    msSolHostReturnLength = (uint64_t)length;
    memcpy(msSolHostReturnProgram, (const void*)msSolHostContext()->programId, 32);
}

uint64_t msSolHostGetReturnData(uint64_t data, uint64_t length, uint64_t programId) {
    uint64_t copied = length < msSolHostReturnLength ? length : msSolHostReturnLength;
    if (copied != 0) {
        memcpy((void*)data, msSolHostReturnData, (size_t)copied);
        memcpy((void*)programId, msSolHostReturnProgram, 32);
    }
    return msSolHostReturnLength;
}

#endif
