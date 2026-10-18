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
#define MS_SOL_MAX_RETURN_DATA 1024
#define MS_SOL_HOST_LOG_BUDGET 10000
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
    char* text;
    size_t length;
} msSolHostLogLine;

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
static msSolHostLogLine* msSolHostLogLines;
static uint64_t msSolHostLogCount;
static uint64_t msSolHostLogBytes;
static int msSolHostLogTruncated;
static msSolHostInvocation* msSolHostInvocations;
static uint64_t msSolHostInvocationCount;
static uint64_t msSolHostRentReadCount;
static uint8_t msSolHostReturnData[MS_SOL_MAX_RETURN_DATA];
static uint64_t msSolHostReturnLength;
static uint8_t msSolHostReturnProgram[32];
static uint64_t msSolHostClock[5];
static msSolHostHeld msSolHostHolds[MS_SOL_MAX_ACCOUNTS];
static uint64_t msSolHostHoldCount;
static void msSolHostHoldAccounts(void);

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
    for (uint64_t index = 0; index < msSolHostLogCount; index++) free(msSolHostLogLines[index].text);
    free(msSolHostLogLines);
    msSolHostLogLines = NULL;
    msSolHostLogCount = 0;
    msSolHostLogBytes = 0;
    msSolHostLogTruncated = 0;
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
    msSolHostRentReadCount = 0;
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
    return msStringNew(msSolHostLogLines[index].text, (int64_t)msSolHostLogLines[index].length);
}

uint64_t msSolHostInvocationTotal(void) { return msSolHostInvocationCount; }
uint64_t msSolHostRentReadTotal(void) { return msSolHostRentReadCount; }

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

static void msSolHostRecordLog(const char* text, size_t length) {
    if (msSolHostFaultCode != 0) return;
    if (msSolHostLogBytes == 0) {
        char program[64];
        msSolHostBase58((const uint8_t*)msSolHostContext()->programId, program);
        msSolHostLogBytes = strlen("Program  invoke [1]") + strlen(program);
    }
    if (msSolHostLogBytes + length >= MS_SOL_HOST_LOG_BUDGET) {
        if (msSolHostLogTruncated) return;
        msSolHostLogTruncated = 1;
        text = "Log truncated";
        length = strlen(text);
    } else {
        msSolHostLogBytes += length;
    }
    msSolHostLogLine* grown = (msSolHostLogLine*)realloc(msSolHostLogLines, (size_t)(msSolHostLogCount + 1) * sizeof(msSolHostLogLine));
    char* copy = (char*)malloc(length + 1);
    if (grown == NULL || copy == NULL) abort();
    memcpy(copy, text, length);
    copy[length] = 0;
    msSolHostLogLines = grown;
    msSolHostLogLines[msSolHostLogCount++] = (msSolHostLogLine){copy, length};
}

static int msSolHostIsUtf8(const uint8_t* bytes, uint64_t length) {
    static const uint32_t smallest[4] = {0, 0x80, 0x800, 0x10000};
    for (uint64_t at = 0; at < length;) {
        uint8_t lead = bytes[at];
        uint32_t extra = lead < 0x80 ? 0 : (lead & 0xe0) == 0xc0 ? 1 : (lead & 0xf0) == 0xe0 ? 2 : (lead & 0xf8) == 0xf0 ? 3 : 4;
        if (extra == 4 || extra >= length - at) return 0;
        uint32_t point = extra == 0 ? lead : lead & (0x3fu >> extra);
        for (uint32_t index = 1; index <= extra; index++) {
            if ((bytes[at + index] & 0xc0) != 0x80) return 0;
            point = (point << 6) | (bytes[at + index] & 0x3f);
        }
        if (point < smallest[extra] || point > 0x10ffff || (point >= 0xd800 && point <= 0xdfff)) return 0;
        at += extra + 1;
    }
    return 1;
}

void msSolHostLog(uint64_t address, uint64_t length) {
    if (!msSolHostIsUtf8((const uint8_t*)address, length)) {
        msSolHostFault(MS_SOL_HOST_REFUSED, "ProgramFailedToComplete: sol_log_: the line is not valid UTF-8");
        return;
    }
    char* line = (char*)malloc((size_t)length + 13);
    if (line == NULL) abort();
    memcpy(line, "Program log: ", 13);
    memcpy(line + 13, (const void*)address, (size_t)length);
    msSolHostRecordLog(line, (size_t)length + 13);
    free(line);
}

void msSolHostLog64(uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e) {
    char line[160];
    snprintf(line, sizeof(line), "Program log: 0x%llx, 0x%llx, 0x%llx, 0x%llx, 0x%llx",
        (unsigned long long)a, (unsigned long long)b, (unsigned long long)c, (unsigned long long)d, (unsigned long long)e);
    msSolHostRecordLog(line, strlen(line));
}

void msSolHostLogPubkey(uint64_t address) {
    char encoded[64];
    char line[96];
    msSolHostBase58((const uint8_t*)address, encoded);
    snprintf(line, sizeof(line), "Program log: %s", encoded);
    msSolHostRecordLog(line, strlen(line));
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
    msSolHostRecordLog(line, at);
    free(line);
}

void msSolHostLogComputeUnits(void) {
    char line[96];
    snprintf(line, sizeof(line), "Program consumption: %llu units remaining", (unsigned long long)MS_SOL_HOST_COMPUTE_BUDGET);
    msSolHostRecordLog(line, strlen(line));
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

#define MS_SOL_HOST_LAMPORTS_PER_BYTE_YEAR 3480ULL
#define MS_SOL_HOST_RENT_EXEMPTION_YEARS 2
#define MS_SOL_HOST_ACCOUNT_STORAGE_OVERHEAD 128ULL

static uint64_t msSolHostRentExempt(uint64_t length) {
    return (length + MS_SOL_HOST_ACCOUNT_STORAGE_OVERHEAD) * MS_SOL_HOST_LAMPORTS_PER_BYTE_YEAR * MS_SOL_HOST_RENT_EXEMPTION_YEARS;
}

static uint64_t msSolHostResize(uint8_t* record, uint64_t space) {
    uint64_t length;
    memcpy(&length, record + 80, 8);
    if (space > length) {
        if (space > msSolDataRoom((uint64_t)(uintptr_t)record)) return 20ULL << 32;
        memset(record + 88 + length, 0, (size_t)(space - length));
    }
    memcpy(record + 80, &space, 8);
    return 0;
}

#define MS_SOL_HOST_INVALID_INSTRUCTION_DATA (3ULL << 32)

static uint64_t msSolHostNotSimulated(const char* program, unsigned instruction, uint64_t status) {
    char text[sizeof(msSolHostFaultText)];
    snprintf(text, sizeof(text), "sol_invoke_signed: %s program instruction %u is not simulated", program, instruction);
    msSolHostFault(MS_SOL_HOST_NOT_SIMULATED, text);
    return status;
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

static const uint8_t msSolHostNativeMint[32] = {
    0x06, 0x9b, 0x88, 0x57, 0xfe, 0xab, 0x81, 0x84, 0xfb, 0x68, 0x7f, 0x63, 0x46, 0x18, 0xc0, 0x35,
    0xda, 0xc4, 0x39, 0xdc, 0x1a, 0xeb, 0x3b, 0x55, 0x98, 0xa0, 0xf0, 0x00, 0x00, 0x00, 0x00, 0x01,
};
static const uint8_t msSolHostNativeMint2022[32] = {
    0x83, 0x0d, 0xfc, 0x9f, 0xde, 0x5f, 0xe6, 0xb8, 0xaa, 0x7c, 0x04, 0xa4, 0x76, 0xe9, 0x1e, 0x8a,
    0xc6, 0xbb, 0x26, 0x4a, 0xad, 0x90, 0xfa, 0x19, 0xc9, 0xdf, 0x49, 0xd8, 0x5c, 0x3e, 0x5b, 0x5e,
};

#define MS_SOL_HOST_INVALID_ARGUMENT (2ULL << 32)
#define MS_SOL_HOST_INVALID_ACCOUNT_DATA (4ULL << 32)
#define MS_SOL_HOST_INCORRECT_PROGRAM_ID (7ULL << 32)
#define MS_SOL_HOST_MISSING_REQUIRED_SIGNATURE (8ULL << 32)
#define MS_SOL_HOST_NOT_ENOUGH_ACCOUNT_KEYS (11ULL << 32)
#define MS_SOL_HOST_INVALID_SEEDS (14ULL << 32)
#define MS_SOL_HOST_ILLEGAL_OWNER (18ULL << 32)
#define MS_SOL_HOST_UNINITIALIZED_ACCOUNT (10ULL << 32)
#define MS_SOL_HOST_TOKEN_NOT_RENT_EXEMPT (1ULL << 32)
#define MS_SOL_HOST_TOKEN_INSUFFICIENT_FUNDS 1ULL
#define MS_SOL_HOST_TOKEN_INVALID_MINT 2ULL
#define MS_SOL_HOST_TOKEN_MINT_MISMATCH 3ULL
#define MS_SOL_HOST_TOKEN_OWNER_MISMATCH 4ULL
#define MS_SOL_HOST_TOKEN_FIXED_SUPPLY 5ULL
#define MS_SOL_HOST_TOKEN_ALREADY_IN_USE 6ULL
#define MS_SOL_HOST_TOKEN_NATIVE_NOT_SUPPORTED 10ULL
#define MS_SOL_HOST_TOKEN_NON_NATIVE_HAS_BALANCE 11ULL
#define MS_SOL_HOST_TOKEN_INVALID_INSTRUCTION 12ULL
#define MS_SOL_HOST_TOKEN_OVERFLOW 14ULL
#define MS_SOL_HOST_TOKEN_MINT_REQUIRED_FOR_TRANSFER 31ULL
#define MS_SOL_HOST_TOKEN_NON_TRANSFERABLE 37ULL
#define MS_SOL_HOST_TOKEN_AUTHORITY_TYPE_NOT_SUPPORTED 15ULL
#define MS_SOL_HOST_TOKEN_MINT_CANNOT_FREEZE 16ULL
#define MS_SOL_HOST_TOKEN_ACCOUNT_FROZEN 17ULL
#define MS_SOL_HOST_TOKEN_MINT_DECIMALS_MISMATCH 18ULL
#define MS_SOL_HOST_TOKEN_IMMUTABLE_OWNER 34ULL
#define MS_SOL_HOST_TOKEN_ACCOUNT_LENGTH 165ULL
#define MS_SOL_HOST_TOKEN_MINT_LENGTH 82ULL
#define MS_SOL_HOST_TOKEN_MULTISIG_LENGTH 355ULL

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

static int msSolHostIsToken2022(const uint64_t* header) {
    return memcmp((const void*)header[0], msSolHostToken2022Program, 32) == 0;
}

static int msSolHostOwnedByCallee(const uint64_t* header, const uint8_t* record) {
    return memcmp(record + 40, (const void*)header[0], 32) == 0;
}

static uint64_t msSolHostForeignAccount(const uint64_t* header) {
    if (!msSolHostIsToken2022(header)) {
        msSolHostFault(MS_SOL_HOST_REFUSED, "ExternalAccountDataModified: sol_invoke_signed: the Token program wrote an account it does not own");
    }
    return MS_SOL_HOST_INCORRECT_PROGRAM_ID;
}

static int msSolHostHasTokenLayout(const uint64_t* header, const uint8_t* record, uint64_t base, uint8_t accountType) {
    uint64_t length = msSolHostLoadU64(record + 80);
    if (length == base) return 1;
    return msSolHostIsToken2022(header) && length > MS_SOL_HOST_TOKEN_ACCOUNT_LENGTH
        && length != MS_SOL_HOST_TOKEN_MULTISIG_LENGTH && record[88 + MS_SOL_HOST_TOKEN_ACCOUNT_LENGTH] == accountType;
}

static uint64_t msSolHostPutExtension(uint8_t* out, uint16_t kind, uint16_t length) {
    memcpy(out, &kind, 2);
    memcpy(out + 2, &length, 2);
    memset(out + 4, 0, length);
    return 4ULL + length;
}

static uint64_t msSolHostAccountExtensionsOf(const uint8_t* mint, int immutableOwner, uint8_t out[32], uint8_t* state) {
    uint64_t length = msSolHostLoadU64(mint + 80);
    const uint8_t* data = mint + 88;
    uint64_t written = immutableOwner ? msSolHostPutExtension(out, 7, 0) : 0;
    uint32_t seen = 0;
    uint64_t offset = MS_SOL_HOST_TOKEN_ACCOUNT_LENGTH + 1;
    while (offset + 4 <= length) {
        uint16_t kind, size;
        memcpy(&kind, data + offset, 2);
        memcpy(&size, data + offset + 2, 2);
        if (kind == 0 || size > length - offset - 4) break;
        int first = kind < 32 && (seen & (1u << kind)) == 0;
        if (kind < 32) seen |= 1u << kind;
        if (first) {
            switch (kind) {
            case 1: written += msSolHostPutExtension(out + written, 2, 8); break;
            case 6: if (size >= 1) *state = data[offset + 4]; break;
            case 9:
                written += msSolHostPutExtension(out + written, 13, 0);
                if (!immutableOwner) written += msSolHostPutExtension(out + written, 7, 0);
                break;
            case 14: written += msSolHostPutExtension(out + written, 15, 1); break;
            case 26: written += msSolHostPutExtension(out + written, 27, 0); break;
            default: break;
            }
        }
        offset += 4ULL + size;
    }
    return written;
}

static uint64_t msSolHostShortData(const uint64_t* header) {
    return msSolHostIsToken2022(header) ? MS_SOL_HOST_INVALID_INSTRUCTION_DATA : MS_SOL_HOST_TOKEN_INVALID_INSTRUCTION;
}

static int msSolHostFixedDataRefused(const uint64_t* header, uint64_t length) {
    return header[4] < length || (msSolHostIsToken2022(header) && header[4] != length);
}

static uint64_t msSolHostWritten(const uint64_t* header, const uint8_t* record, uint8_t* region, const uint8_t* before, size_t length) {
    if (msSolHostOwnedByCallee(header, record) || memcmp(region, before, length) == 0) return 0;
    memcpy(region, before, length);
    return msSolHostForeignAccount(header);
}

static uint64_t msSolHostInitializeAccount3(const uint64_t* header, uint8_t* account, const uint8_t* mint, int immutableOwner) {
    const uint8_t* data = (const uint8_t*)header[3];
    if (msSolHostFixedDataRefused(header, 33)) return msSolHostShortData(header);
    if (account == NULL || mint == NULL) return MS_SOL_HOST_NOT_ENOUGH_ACCOUNT_KEYS;
    if (msSolHostIsToken2022(header) && !msSolHostOwnedByCallee(header, account)) return MS_SOL_HOST_INCORRECT_PROGRAM_ID;
    uint64_t length = msSolHostLoadU64(account + 80);
    uint8_t* fields = account + 88;
    if (!msSolHostHasTokenLayout(header, account, MS_SOL_HOST_TOKEN_ACCOUNT_LENGTH, 0)) return MS_SOL_HOST_INVALID_ACCOUNT_DATA;
    if (fields[108] != 0) return MS_SOL_HOST_TOKEN_ALREADY_IN_USE;
    uint64_t reserve = msSolHostRentExempt(length);
    if (msSolHostLamports(account) < reserve) return MS_SOL_HOST_TOKEN_NOT_RENT_EXEMPT;
    int native = memcmp(mint + 8, msSolHostIsToken2022(header) ? msSolHostNativeMint2022 : msSolHostNativeMint, 32) == 0;
    if (!native) {
        if (!msSolHostOwnedByCallee(header, mint)) return MS_SOL_HOST_INCORRECT_PROGRAM_ID;
        if (!msSolHostHasTokenLayout(header, mint, MS_SOL_HOST_TOKEN_MINT_LENGTH, 1) || mint[88 + 45] != 1) {
            return MS_SOL_HOST_TOKEN_INVALID_MINT;
        }
    }
    uint8_t extensions[32];
    uint8_t state = 1;
    uint64_t extensionBytes = msSolHostIsToken2022(header) ? msSolHostAccountExtensionsOf(mint, immutableOwner, extensions, &state) : 0;
    if (extensionBytes != 0 && length < MS_SOL_HOST_TOKEN_ACCOUNT_LENGTH + 1 + extensionBytes) {
        return MS_SOL_HOST_INVALID_ACCOUNT_DATA;
    }
    if (!msSolHostOwnedByCallee(header, account)) return msSolHostForeignAccount(header);
    memcpy(fields, mint + 8, 32);
    memcpy(fields + 32, data + 1, 32);
    fields[108] = state;
    if (native) {
        fields[109] = 1;
        msSolHostStoreU64(fields + 113, reserve);
        msSolHostStoreU64(fields + 64, msSolHostLamports(account) - reserve);
    }
    if (length > MS_SOL_HOST_TOKEN_ACCOUNT_LENGTH) {
        fields[MS_SOL_HOST_TOKEN_ACCOUNT_LENGTH] = 2;
        memcpy(fields + MS_SOL_HOST_TOKEN_ACCOUNT_LENGTH + 1, extensions, (size_t)extensionBytes);
    }
    return 0;
}

static uint64_t msSolHostInitialized(const uint64_t* header, const uint8_t* record, uint64_t base, uint8_t accountType, uint64_t initializedAt) {
    if (record == NULL) return MS_SOL_HOST_NOT_ENOUGH_ACCOUNT_KEYS;
    if (!msSolHostHasTokenLayout(header, record, base, accountType)) return MS_SOL_HOST_INVALID_ACCOUNT_DATA;
    if (record[88 + initializedAt] == 0) return MS_SOL_HOST_UNINITIALIZED_ACCOUNT;
    return 0;
}

static uint64_t msSolHostTokenAccount(const uint64_t* header, const uint8_t* record) {
    return msSolHostInitialized(header, record, MS_SOL_HOST_TOKEN_ACCOUNT_LENGTH, 2, 108);
}

static uint64_t msSolHostMint(const uint64_t* header, const uint8_t* record) {
    return msSolHostInitialized(header, record, MS_SOL_HOST_TOKEN_MINT_LENGTH, 1, 45);
}

static uint64_t msSolHostUnpacked(const uint64_t* header, const uint8_t* record, uint64_t base, uint8_t accountType, uint64_t initializedAt) {
    if (record == NULL) return MS_SOL_HOST_NOT_ENOUGH_ACCOUNT_KEYS;
    if (msSolHostIsToken2022(header) && !msSolHostOwnedByCallee(header, record)) return MS_SOL_HOST_INCORRECT_PROGRAM_ID;
    return msSolHostInitialized(header, record, base, accountType, initializedAt);
}

static uint64_t msSolHostUnpackedAccount(const uint64_t* header, const uint8_t* record) {
    return msSolHostUnpacked(header, record, MS_SOL_HOST_TOKEN_ACCOUNT_LENGTH, 2, 108);
}

static uint64_t msSolHostUnpackedMint(const uint64_t* header, const uint8_t* record) {
    return msSolHostUnpacked(header, record, MS_SOL_HOST_TOKEN_MINT_LENGTH, 1, 45);
}

static int msSolHostOptionIs(const uint8_t* option, const uint8_t* key) {
    uint32_t tag;
    memcpy(&tag, option, 4);
    return tag == 1 && memcmp(option + 4, key, 32) == 0;
}

static void msSolHostStoreOption(const uint64_t* header, uint8_t* option, const uint8_t* key) {
    uint32_t tag = key != NULL;
    memcpy(option, &tag, 4);
    if (key != NULL) memcpy(option + 4, key, 32);
    else if (msSolHostIsToken2022(header)) memset(option + 4, 0, 32);
}

static int msSolHostHasExtension(const uint8_t* record, uint16_t wanted) {
    uint64_t length = msSolHostLoadU64(record + 80);
    const uint8_t* data = record + 88;
    uint64_t offset = MS_SOL_HOST_TOKEN_ACCOUNT_LENGTH + 1;
    while (offset + 4 <= length) {
        uint16_t kind, size;
        memcpy(&kind, data + offset, 2);
        memcpy(&size, data + offset + 2, 2);
        if (kind == 0 || size > length - offset - 4) break;
        if (kind == wanted) return 1;
        offset += 4ULL + size;
    }
    return 0;
}

static uint64_t msSolHostAuthorized(const uint64_t* header, uint64_t index, const uint8_t* expected) {
    const uint8_t* authority = msSolHostRecordOf(header, index);
    if (authority == NULL) return MS_SOL_HOST_NOT_ENOUGH_ACCOUNT_KEYS;
    if (memcmp(expected, authority + 8, 32) != 0) return MS_SOL_HOST_TOKEN_OWNER_MISMATCH;
    if (msSolHostOwnedByCallee(header, authority) && msSolHostLoadU64(authority + 80) == MS_SOL_HOST_TOKEN_MULTISIG_LENGTH) {
        msSolHostFault(MS_SOL_HOST_NOT_SIMULATED, "sol_invoke_signed: a multisignature token authority is not simulated");
        return MS_SOL_HOST_MISSING_REQUIRED_SIGNATURE;
    }
    if (((const uint8_t*)(header[1] + index * 16))[9] == 0) return MS_SOL_HOST_MISSING_REQUIRED_SIGNATURE;
    return 0;
}

static const uint8_t msSolHostIncinerator[32] = {
    0x00, 0x33, 0x90, 0x72, 0x8d, 0x34, 0x11, 0x60, 0x79, 0xbd, 0xc9, 0x11, 0xbf, 0xff, 0x00, 0xdb,
    0xd4, 0x4d, 0x2e, 0xcd, 0xcc, 0xf7, 0x9c, 0xa6, 0xe1, 0x00, 0x38, 0xe1, 0x00, 0x00, 0x00, 0x00,
};

static uint64_t msSolHostBurn(const uint64_t* header, int checked) {
    static const uint8_t systemProgram[32] = {0};
    const uint8_t* data = (const uint8_t*)header[3];
    uint8_t* source = msSolHostRecordOf(header, 0);
    uint8_t* mint = msSolHostRecordOf(header, 1);
    const uint8_t* authority = msSolHostRecordOf(header, 2);
    if (msSolHostFixedDataRefused(header, checked ? 10 : 9)) return msSolHostShortData(header);
    if (source == NULL || mint == NULL || authority == NULL) return MS_SOL_HOST_NOT_ENOUGH_ACCOUNT_KEYS;
    uint64_t amount = msSolHostLoadU64(data + 1);
    uint64_t status = msSolHostUnpackedAccount(header, source);
    if (status == 0) status = msSolHostUnpackedMint(header, mint);
    if (status != 0) return status;
    uint8_t* account = source + 88;
    if (account[108] == 2) return MS_SOL_HOST_TOKEN_ACCOUNT_FROZEN;
    if (account[109] == 1) return MS_SOL_HOST_TOKEN_NATIVE_NOT_SUPPORTED;
    if (msSolHostLoadU64(account + 64) < amount) return MS_SOL_HOST_TOKEN_INSUFFICIENT_FUNDS;
    if (memcmp(mint + 8, account, 32) != 0) return MS_SOL_HOST_TOKEN_MINT_MISMATCH;
    if (checked && data[9] != mint[88 + 44]) return MS_SOL_HOST_TOKEN_MINT_DECIMALS_MISMATCH;
    int anyoneBurns = memcmp(account + 32, systemProgram, 32) == 0 || memcmp(account + 32, msSolHostIncinerator, 32) == 0;
    int delegated = !anyoneBurns && msSolHostOptionIs(account + 72, authority + 8);
    if (!anyoneBurns) {
        status = msSolHostAuthorized(header, 2, delegated ? account + 76 : account + 32);
        if (status != 0) return status;
    }
    uint64_t allowance = msSolHostLoadU64(account + 121);
    if (delegated && allowance < amount) return MS_SOL_HOST_TOKEN_INSUFFICIENT_FUNDS;
    int foreign = !msSolHostOwnedByCallee(header, source) || !msSolHostOwnedByCallee(header, mint);
    if (amount == 0 && foreign) return MS_SOL_HOST_INCORRECT_PROGRAM_ID;
    if (foreign) return msSolHostForeignAccount(header);
    if (delegated) {
        msSolHostStoreU64(account + 121, allowance - amount);
        if (allowance == amount) msSolHostStoreOption(header, account + 72, NULL);
    }
    msSolHostStoreU64(account + 64, msSolHostLoadU64(account + 64) - amount);
    msSolHostStoreU64(mint + 88 + 36, msSolHostLoadU64(mint + 88 + 36) - amount);
    return 0;
}

static uint64_t msSolHostApproveChecked(const uint64_t* header) {
    const uint8_t* data = (const uint8_t*)header[3];
    uint8_t* source = msSolHostRecordOf(header, 0);
    const uint8_t* mint = msSolHostRecordOf(header, 1);
    const uint8_t* delegate = msSolHostRecordOf(header, 2);
    if (msSolHostFixedDataRefused(header, 10)) return msSolHostShortData(header);
    if (source == NULL || mint == NULL || delegate == NULL || msSolHostRecordOf(header, 3) == NULL) {
        return MS_SOL_HOST_NOT_ENOUGH_ACCOUNT_KEYS;
    }
    uint64_t status = msSolHostUnpackedAccount(header, source);
    if (status != 0) return status;
    uint8_t* fields = source + 88;
    if (fields[108] == 2) return MS_SOL_HOST_TOKEN_ACCOUNT_FROZEN;
    if (memcmp(fields, mint + 8, 32) != 0) return MS_SOL_HOST_TOKEN_MINT_MISMATCH;
    status = msSolHostUnpackedMint(header, mint);
    if (status != 0) return status;
    if (data[9] != mint[88 + 44]) return MS_SOL_HOST_TOKEN_MINT_DECIMALS_MISMATCH;
    status = msSolHostAuthorized(header, 3, fields + 32);
    if (status != 0) return status;
    uint8_t before[MS_SOL_HOST_TOKEN_ACCOUNT_LENGTH];
    memcpy(before, fields, sizeof before);
    msSolHostStoreOption(header, fields + 72, delegate + 8);
    msSolHostStoreU64(fields + 121, msSolHostLoadU64(data + 1));
    return msSolHostWritten(header, source, fields, before, sizeof before);
}

static uint64_t msSolHostRevoke(const uint64_t* header) {
    uint8_t* source = msSolHostRecordOf(header, 0);
    const uint8_t* authority = msSolHostRecordOf(header, 1);
    if (msSolHostIsToken2022(header) && authority == NULL) return MS_SOL_HOST_NOT_ENOUGH_ACCOUNT_KEYS;
    uint64_t status = msSolHostUnpackedAccount(header, source);
    if (status != 0) return status;
    if (authority == NULL) return MS_SOL_HOST_NOT_ENOUGH_ACCOUNT_KEYS;
    uint8_t* fields = source + 88;
    if (fields[108] == 2) return MS_SOL_HOST_TOKEN_ACCOUNT_FROZEN;
    int byDelegate = msSolHostOptionIs(fields + 72, authority + 8);
    status = msSolHostAuthorized(header, 1, byDelegate ? fields + 76 : fields + 32);
    if (status != 0) return status;
    uint8_t before[MS_SOL_HOST_TOKEN_ACCOUNT_LENGTH];
    memcpy(before, fields, sizeof before);
    msSolHostStoreOption(header, fields + 72, NULL);
    msSolHostStoreU64(fields + 121, 0);
    return msSolHostWritten(header, source, fields, before, sizeof before);
}

static int msSolHostSameKey(const uint8_t* left, const uint8_t* right) {
    return memcmp(left + 8, right + 8, 32) == 0;
}

static uint64_t msSolHostMintTo(const uint64_t* header) {
    const uint8_t* data = (const uint8_t*)header[3];
    uint8_t* mint = msSolHostRecordOf(header, 0);
    uint8_t* destination = msSolHostRecordOf(header, 1);
    int extended = msSolHostIsToken2022(header);
    if (msSolHostFixedDataRefused(header, 9)) return msSolHostShortData(header);
    if (mint == NULL || destination == NULL || msSolHostRecordOf(header, 2) == NULL) return MS_SOL_HOST_NOT_ENOUGH_ACCOUNT_KEYS;
    uint64_t amount = msSolHostLoadU64(data + 1);
    uint64_t status = msSolHostUnpackedAccount(header, destination);
    if (status != 0) return status;
    uint8_t* to = destination + 88;
    if (to[108] == 2) return MS_SOL_HOST_TOKEN_ACCOUNT_FROZEN;
    if (to[109] == 1) return MS_SOL_HOST_TOKEN_NATIVE_NOT_SUPPORTED;
    if (memcmp(mint + 8, to, 32) != 0) return MS_SOL_HOST_TOKEN_MINT_MISMATCH;
    status = msSolHostUnpackedMint(header, mint);
    if (status != 0) return status;
    uint8_t* minted = mint + 88;
    if (minted[0] == 0) return MS_SOL_HOST_TOKEN_FIXED_SUPPLY;
    status = msSolHostAuthorized(header, 2, minted + 4);
    if (status != 0) return status;
    int foreign = !msSolHostOwnedByCallee(header, mint) || !msSolHostOwnedByCallee(header, destination);
    if (amount == 0 && foreign) return MS_SOL_HOST_INCORRECT_PROGRAM_ID;
    uint64_t held = msSolHostLoadU64(to + 64);
    uint64_t supply = msSolHostLoadU64(minted + 36);
    if ((extended && amount > UINT64_MAX - held) || amount > UINT64_MAX - supply) return MS_SOL_HOST_TOKEN_OVERFLOW;
    if (foreign) return msSolHostForeignAccount(header);
    msSolHostStoreU64(to + 64, held + amount);
    msSolHostStoreU64(minted + 36, supply + amount);
    return 0;
}

static uint64_t msSolHostTransfer(const uint64_t* header, int checked) {
    const uint8_t* data = (const uint8_t*)header[3];
    uint64_t authorityAt = checked ? 3 : 2;
    uint8_t* source = msSolHostRecordOf(header, 0);
    const uint8_t* mint = checked ? msSolHostRecordOf(header, 1) : NULL;
    uint8_t* destination = msSolHostRecordOf(header, authorityAt - 1);
    const uint8_t* authority = msSolHostRecordOf(header, authorityAt);
    int extended = msSolHostIsToken2022(header);
    if (msSolHostFixedDataRefused(header, checked ? 10 : 9)) return msSolHostShortData(header);
    if (source == NULL || destination == NULL || authority == NULL || (checked && mint == NULL)) {
        return MS_SOL_HOST_NOT_ENOUGH_ACCOUNT_KEYS;
    }
    uint64_t amount = msSolHostLoadU64(data + 1);
    uint64_t status = msSolHostUnpackedAccount(header, source);
    if (status == 0 && !extended) status = msSolHostTokenAccount(header, destination);
    if (status != 0) return status;
    uint8_t* from = source + 88;
    uint8_t* to = destination + 88;
    if (from[108] == 2 || (!extended && to[108] == 2)) return MS_SOL_HOST_TOKEN_ACCOUNT_FROZEN;
    uint64_t held = msSolHostLoadU64(from + 64);
    if (held < amount) return MS_SOL_HOST_TOKEN_INSUFFICIENT_FUNDS;
    if (extended && msSolHostHasExtension(source, 13)) return MS_SOL_HOST_TOKEN_NON_TRANSFERABLE;
    if (extended && !checked && (msSolHostHasExtension(source, 2) || msSolHostHasExtension(source, 15) || msSolHostHasExtension(source, 27))) {
        return MS_SOL_HOST_TOKEN_MINT_REQUIRED_FOR_TRANSFER;
    }
    if (!extended && memcmp(from, to, 32) != 0) return MS_SOL_HOST_TOKEN_MINT_MISMATCH;
    if (checked) {
        if (memcmp(mint + 8, from, 32) != 0) return MS_SOL_HOST_TOKEN_MINT_MISMATCH;
        status = extended ? msSolHostUnpackedMint(header, mint) : msSolHostMint(header, mint);
        if (status != 0) return status;
        if (data[9] != mint[88 + 44]) return MS_SOL_HOST_TOKEN_MINT_DECIMALS_MISMATCH;
    }
    int delegated = msSolHostOptionIs(from + 72, authority + 8);
    status = msSolHostAuthorized(header, authorityAt, delegated ? from + 76 : from + 32);
    if (status != 0) return status;
    uint64_t allowance = msSolHostLoadU64(from + 121);
    if (delegated && allowance < amount) return MS_SOL_HOST_TOKEN_INSUFFICIENT_FUNDS;
    int toItself = msSolHostSameKey(source, destination);
    int foreign = !msSolHostOwnedByCallee(header, source) || !msSolHostOwnedByCallee(header, destination);
    if ((toItself || amount == 0) && foreign) return MS_SOL_HOST_INCORRECT_PROGRAM_ID;
    if (toItself) return 0;
    if (extended) {
        status = msSolHostUnpackedAccount(header, destination);
        if (status != 0) return status;
        if (to[108] == 2) return MS_SOL_HOST_TOKEN_ACCOUNT_FROZEN;
        if (memcmp(from, to, 32) != 0) return MS_SOL_HOST_TOKEN_MINT_MISMATCH;
    }
    uint64_t received = msSolHostLoadU64(to + 64);
    int native = from[109] == 1;
    if (extended && (amount > UINT64_MAX - received || (native && msSolHostLamports(source) < amount))) {
        return MS_SOL_HOST_TOKEN_OVERFLOW;
    }
    if (foreign) return msSolHostForeignAccount(header);
    if (native && msSolHostLamports(source) < amount) {
        msSolHostFault(MS_SOL_HOST_REFUSED, "UnbalancedInstruction: sol_invoke_signed: the Token program moved more lamports than the native account holds");
        return MS_SOL_HOST_TOKEN_OVERFLOW;
    }
    if (delegated) {
        msSolHostStoreU64(from + 121, allowance - amount);
        if (allowance == amount) msSolHostStoreOption(header, from + 72, NULL);
    }
    msSolHostStoreU64(from + 64, held - amount);
    msSolHostStoreU64(to + 64, received + amount);
    if (native) {
        msSolHostSetLamports(source, msSolHostLamports(source) - amount);
        msSolHostSetLamports(destination, msSolHostLamports(destination) + amount);
    }
    return 0;
}

static uint64_t msSolHostCloseAccount(const uint64_t* header) {
    static const uint8_t systemProgram[32] = {0};
    uint8_t* source = msSolHostRecordOf(header, 0);
    uint8_t* destination = msSolHostRecordOf(header, 1);
    if (source == NULL || destination == NULL || msSolHostRecordOf(header, 2) == NULL) return MS_SOL_HOST_NOT_ENOUGH_ACCOUNT_KEYS;
    if (msSolHostSameKey(source, destination)) return MS_SOL_HOST_INVALID_ACCOUNT_DATA;
    if (msSolHostIsToken2022(header) && msSolHostOwnedByCallee(header, source)
        && msSolHostHasTokenLayout(header, source, MS_SOL_HOST_TOKEN_MINT_LENGTH, 1) && msSolHostHasExtension(source, 3)) {
        msSolHostFault(MS_SOL_HOST_NOT_SIMULATED, "sol_invoke_signed: closing a Token-2022 mint that has a close authority is not simulated");
        return MS_SOL_HOST_INVALID_ACCOUNT_DATA;
    }
    uint64_t status = msSolHostUnpackedAccount(header, source);
    if (status != 0) return status;
    uint8_t* fields = source + 88;
    if (fields[109] != 1 && msSolHostLoadU64(fields + 64) != 0) return MS_SOL_HOST_TOKEN_NON_NATIVE_HAS_BALANCE;
    if (memcmp(fields + 32, systemProgram, 32) == 0 || memcmp(fields + 32, msSolHostIncinerator, 32) == 0) {
        if (memcmp(destination + 8, msSolHostIncinerator, 32) != 0) return MS_SOL_HOST_INVALID_ACCOUNT_DATA;
    } else {
        status = msSolHostAuthorized(header, 2, fields[129] == 1 ? fields + 133 : fields + 32);
        if (status != 0) return status;
    }
    uint64_t lamports = msSolHostLamports(source);
    if (lamports > UINT64_MAX - msSolHostLamports(destination)) return MS_SOL_HOST_TOKEN_OVERFLOW;
    if (!msSolHostOwnedByCallee(header, source)) {
        msSolHostFault(MS_SOL_HOST_REFUSED, "ExternalAccountLamportSpend: sol_invoke_signed: the Token program spent the lamports of an account it does not own");
        return MS_SOL_HOST_INCORRECT_PROGRAM_ID;
    }
    msSolHostSetLamports(destination, msSolHostLamports(destination) + lamports);
    msSolHostSetLamports(source, 0);
    memset(fields, 0, (size_t)msSolHostLoadU64(source + 80));
    msSolHostResize(source, 0);
    memset(source + 40, 0, 32);
    return 0;
}

static uint64_t msSolHostAuthorityOf(const uint64_t* header, uint8_t* target, uint8_t* option, const uint8_t* holder, const uint8_t* next) {
    uint64_t status = msSolHostAuthorized(header, 1, holder);
    if (status != 0) return status;
    uint8_t before[36];
    memcpy(before, option, sizeof before);
    msSolHostStoreOption(header, option, next);
    return msSolHostWritten(header, target, option, before, sizeof before);
}

static uint64_t msSolHostSetAuthority(const uint64_t* header) {
    const uint8_t* data = (const uint8_t*)header[3];
    uint8_t* target = msSolHostRecordOf(header, 0);
    if (header[4] < 3 || data[2] > 1 || header[4] < (data[2] == 1 ? 35ULL : 3ULL)) return msSolHostShortData(header);
    if (data[1] > 3) {
        if (msSolHostIsToken2022(header)) msSolHostFault(MS_SOL_HOST_NOT_SIMULATED, "sol_invoke_signed: a Token-2022 extension authority is not simulated");
        return MS_SOL_HOST_TOKEN_INVALID_INSTRUCTION;
    }
    const uint8_t* next = data[2] == 1 ? data + 3 : NULL;
    if (target == NULL || msSolHostRecordOf(header, 1) == NULL) return MS_SOL_HOST_NOT_ENOUGH_ACCOUNT_KEYS;
    if (msSolHostIsToken2022(header) && !msSolHostOwnedByCallee(header, target)) return MS_SOL_HOST_INCORRECT_PROGRAM_ID;
    uint8_t* fields = target + 88;
    uint64_t blank = msSolHostIsToken2022(header) ? MS_SOL_HOST_INVALID_ACCOUNT_DATA : MS_SOL_HOST_UNINITIALIZED_ACCOUNT;
    if (msSolHostHasTokenLayout(header, target, MS_SOL_HOST_TOKEN_ACCOUNT_LENGTH, 2)) {
        if (fields[108] == 0) return blank;
        if (fields[108] == 2) return MS_SOL_HOST_TOKEN_ACCOUNT_FROZEN;
        if (data[1] == 3) return msSolHostAuthorityOf(header, target, fields + 129, fields[129] == 1 ? fields + 133 : fields + 32, next);
        if (data[1] != 2) return MS_SOL_HOST_TOKEN_AUTHORITY_TYPE_NOT_SUPPORTED;
        uint64_t status = msSolHostAuthorized(header, 1, fields + 32);
        if (status != 0) return status;
        if (msSolHostHasExtension(target, 7)) return MS_SOL_HOST_TOKEN_IMMUTABLE_OWNER;
        if (next == NULL) return MS_SOL_HOST_TOKEN_INVALID_INSTRUCTION;
        uint8_t before[MS_SOL_HOST_TOKEN_ACCOUNT_LENGTH];
        memcpy(before, fields, sizeof before);
        memcpy(fields + 32, next, 32);
        msSolHostStoreOption(header, fields + 72, NULL);
        msSolHostStoreU64(fields + 121, 0);
        if (fields[109] == 1) msSolHostStoreOption(header, fields + 129, NULL);
        return msSolHostWritten(header, target, fields, before, sizeof before);
    }
    if (msSolHostHasTokenLayout(header, target, MS_SOL_HOST_TOKEN_MINT_LENGTH, 1)) {
        if (fields[45] == 0) return blank;
        if (data[1] > 1) return MS_SOL_HOST_TOKEN_AUTHORITY_TYPE_NOT_SUPPORTED;
        uint8_t* option = data[1] == 0 ? fields : fields + 46;
        if (option[0] == 0) return data[1] == 0 ? MS_SOL_HOST_TOKEN_FIXED_SUPPLY : MS_SOL_HOST_TOKEN_MINT_CANNOT_FREEZE;
        return msSolHostAuthorityOf(header, target, option, option + 4, next);
    }
    return msSolHostIsToken2022(header) ? MS_SOL_HOST_INVALID_ACCOUNT_DATA : MS_SOL_HOST_INVALID_ARGUMENT;
}

static uint64_t msSolHostInitializeMint2(const uint64_t* header) {
    const uint8_t* data = (const uint8_t*)header[3];
    uint8_t* mint = msSolHostRecordOf(header, 0);
    int extended = msSolHostIsToken2022(header);
    if (header[4] < 35 || data[34] > 1 || header[4] < (data[34] == 1 ? 67ULL : 35ULL)) return msSolHostShortData(header);
    if (mint == NULL) return MS_SOL_HOST_NOT_ENOUGH_ACCOUNT_KEYS;
    if (extended && !msSolHostOwnedByCallee(header, mint)) return MS_SOL_HOST_INCORRECT_PROGRAM_ID;
    uint64_t length = msSolHostLoadU64(mint + 80);
    if (length != MS_SOL_HOST_TOKEN_MINT_LENGTH) {
        if (extended && length > MS_SOL_HOST_TOKEN_ACCOUNT_LENGTH) {
            msSolHostFault(MS_SOL_HOST_NOT_SIMULATED, "sol_invoke_signed: InitializeMint2 of a Token-2022 mint with extensions is not simulated");
        }
        return MS_SOL_HOST_INVALID_ACCOUNT_DATA;
    }
    uint8_t* fields = mint + 88;
    int belowRent = msSolHostLamports(mint) < msSolHostRentExempt(MS_SOL_HOST_TOKEN_MINT_LENGTH);
    if (extended && belowRent) return MS_SOL_HOST_TOKEN_NOT_RENT_EXEMPT;
    if (fields[45] != 0) return MS_SOL_HOST_TOKEN_ALREADY_IN_USE;
    if (belowRent) return MS_SOL_HOST_TOKEN_NOT_RENT_EXEMPT;
    if (!msSolHostOwnedByCallee(header, mint)) return msSolHostForeignAccount(header);
    msSolHostStoreOption(header, fields, data + 2);
    fields[44] = data[1];
    fields[45] = 1;
    msSolHostStoreOption(header, fields + 46, data[34] == 1 ? data + 35 : NULL);
    return 0;
}

static int msSolHostAnyByte(const uint8_t* bytes, uint64_t from, uint64_t to) {
    for (uint64_t index = from; index < to; index++) {
        if (bytes[index] != 0) return 1;
    }
    return 0;
}

static int msSolHostExtensionInForce(uint16_t kind, const uint8_t* body, uint16_t size) {
    switch (kind) {
    case 1: return size >= 108 && (msSolHostAnyByte(body, 88, 90) || msSolHostAnyByte(body, 106, 108));
    case 14: return size >= 64 && msSolHostAnyByte(body, 32, 64);
    case 26: return size >= 33 && body[32] != 0;
    case 2: case 4: case 5: case 8: case 11: case 12: case 16: case 17: case 24:
        return msSolHostAnyByte(body, 0, size);
    default: return 0;
    }
}

static int msSolHostExtensionNotSimulated(const uint64_t* header) {
    for (uint64_t index = 0; index < header[2]; index++) {
        const uint8_t* record = msSolHostRecordOf(header, index);
        uint64_t length = msSolHostLoadU64(record + 80);
        if (!msSolHostOwnedByCallee(header, record) || length == MS_SOL_HOST_TOKEN_MULTISIG_LENGTH) continue;
        const uint8_t* data = record + 88;
        uint64_t offset = MS_SOL_HOST_TOKEN_ACCOUNT_LENGTH + 1;
        while (offset + 4 <= length) {
            uint16_t kind, size;
            memcpy(&kind, data + offset, 2);
            memcpy(&size, data + offset + 2, 2);
            if (kind == 0 || size > length - offset - 4) break;
            if (msSolHostExtensionInForce(kind, data + offset + 4, size)) {
                char text[sizeof(msSolHostFaultText)];
                snprintf(text, sizeof(text), "sol_invoke_signed: Token-2022 extension %u with a setting in force is not simulated", (unsigned)kind);
                msSolHostFault(MS_SOL_HOST_NOT_SIMULATED, text);
                return 1;
            }
            offset += 4ULL + size;
        }
    }
    return 0;
}

static uint64_t msSolHostToken(const uint64_t* header) {
    if (header[4] < 1) return MS_SOL_HOST_TOKEN_INVALID_INSTRUCTION;
    if (msSolHostIsToken2022(header) && msSolHostExtensionNotSimulated(header)) return MS_SOL_HOST_INVALID_ACCOUNT_DATA;
    const uint8_t* data = (const uint8_t*)header[3];
    switch (data[0]) {
    case 3:
        return msSolHostTransfer(header, 0);
    case 7:
        return msSolHostMintTo(header);
    case 9:
        return msSolHostCloseAccount(header);
    case 12:
        return msSolHostTransfer(header, 1);
    case 5:
        return msSolHostRevoke(header);
    case 6:
        return msSolHostSetAuthority(header);
    case 13:
        return msSolHostApproveChecked(header);
    case 8:
        return msSolHostBurn(header, 0);
    case 15:
        return msSolHostBurn(header, 1);
    case 18:
        return msSolHostInitializeAccount3(header, msSolHostRecordOf(header, 0), msSolHostRecordOf(header, 1), 0);
    case 20:
        return msSolHostInitializeMint2(header);
    default:
        return msSolHostNotSimulated(msSolHostIsToken2022(header) ? "Token-2022" : "Token", data[0],
            MS_SOL_HOST_TOKEN_INVALID_INSTRUCTION);
    }
}

static uint64_t msSolHostAssociated(const uint64_t* header) {
    const uint8_t* data = (const uint8_t*)header[3];
    if (header[4] >= 1 && data[0] > 1) {
        return msSolHostNotSimulated("Associated Token", data[0], MS_SOL_HOST_INVALID_INSTRUCTION_DATA);
    }
    static const uint8_t systemProgram[32] = {0};
    uint8_t* payer = msSolHostRecordOf(header, 0);
    uint8_t* associated = msSolHostRecordOf(header, 1);
    uint8_t* wallet = msSolHostRecordOf(header, 2);
    uint8_t* mint = msSolHostRecordOf(header, 3);
    uint8_t* program = msSolHostRecordOf(header, 5);
    if (payer == NULL || associated == NULL || wallet == NULL || mint == NULL || program == NULL) {
        return MS_SOL_HOST_NOT_ENOUGH_ACCOUNT_KEYS;
    }
    const uint64_t seeds[6] = {
        (uint64_t)(uintptr_t)(wallet + 8), 32, (uint64_t)(uintptr_t)(program + 8), 32, (uint64_t)(uintptr_t)(mint + 8), 32,
    };
    uint8_t address[32];
    int derived = 0;
    for (int bump = 255; bump >= 0 && !derived; bump--) {
        uint8_t last = (uint8_t)bump;
        derived = msSolHostDerive((uint64_t)(uintptr_t)seeds, 3, &last, (uint64_t)(uintptr_t)msSolHostAssociatedProgram, address);
    }
    if (!derived || memcmp(address, associated + 8, 32) != 0) return MS_SOL_HOST_INVALID_SEEDS;
    if (!msSolHostIsTokenProgram(program + 8)) {
        msSolHostFault(MS_SOL_HOST_NOT_SIMULATED, "sol_invoke_signed: an associated account under a program that is not a token program is not simulated");
        return MS_SOL_HOST_INCORRECT_PROGRAM_ID;
    }
    uint8_t initialize[33] = {18};
    memcpy(initialize + 1, wallet + 8, 32);
    const uint64_t inner[5] = {(uint64_t)(uintptr_t)(program + 8), 0, 0, (uint64_t)(uintptr_t)initialize, 33};
    int idempotent = header[4] >= 1 && data[0] == 1;
    if (idempotent && msSolHostOwnedByCallee(inner, associated) && msSolHostTokenAccount(inner, associated) == 0) {
        if (memcmp(associated + 88 + 32, wallet + 8, 32) != 0) return 1ULL << 32;
        if (memcmp(associated + 88, mint + 8, 32) != 0) return MS_SOL_HOST_INVALID_ACCOUNT_DATA;
        return 0;
    }
    if (memcmp(associated + 40, systemProgram, 32) != 0) return MS_SOL_HOST_ILLEGAL_OWNER;
    if (msSolHostLoadU64(associated + 80) != 0) {
        msSolHostFault(MS_SOL_HOST_NOT_SIMULATED, "sol_invoke_signed: an associated account at a System-owned address that holds data is not simulated");
        return MS_SOL_HOST_INVALID_ACCOUNT_DATA;
    }
    int extended = msSolHostIsToken2022(inner);
    if (memcmp(mint + 8, extended ? msSolHostNativeMint2022 : msSolHostNativeMint, 32) != 0) {
        if (!msSolHostOwnedByCallee(inner, mint)) return MS_SOL_HOST_INCORRECT_PROGRAM_ID;
        if (msSolHostMint(inner, mint) != 0) return MS_SOL_HOST_TOKEN_INVALID_MINT;
    }
    uint8_t extensions[32];
    uint8_t state = 1;
    uint64_t space = MS_SOL_HOST_TOKEN_ACCOUNT_LENGTH;
    if (extended) space += 1 + msSolHostAccountExtensionsOf(mint, 1, extensions, &state);
    uint64_t rent = msSolHostRentExempt(space);
    uint64_t held = msSolHostLamports(associated);
    uint64_t missing = rent > held ? rent - held : 0;
    if (missing != 0) {
        if (((const uint8_t*)header[1])[9] == 0) {
            msSolHostFault(MS_SOL_HOST_REFUSED, "PrivilegeEscalation: sol_invoke_signed: the Associated Token program funds the account from a payer that did not sign");
            return MS_SOL_HOST_MISSING_REQUIRED_SIGNATURE;
        }
        if (msSolHostLamports(payer) < missing) return 1;
    }
    uint64_t status = msSolHostResize(associated, space);
    if (status != 0) return status;
    msSolHostSetLamports(payer, msSolHostLamports(payer) - missing);
    msSolHostSetLamports(associated, held + missing);
    memcpy(associated + 40, program + 8, 32);
    return msSolHostInitializeAccount3(inner, associated, mint, 1);
}

#define MS_SOL_HOST_SYSTEM_ALREADY_IN_USE (1ULL << 32)
#define MS_SOL_HOST_SYSTEM_TOO_FEW_LAMPORTS 1ULL
#define MS_SOL_HOST_SYSTEM_INVALID_DATA_LENGTH 3ULL
#define MS_SOL_HOST_SYSTEM_MAX_SPACE (10ULL * 1024 * 1024)
#define MS_SOL_HOST_ARITHMETIC_OVERFLOW (24ULL << 32)

typedef struct {
    uint8_t* record;
    uint64_t lamports;
    uint64_t space;
    const uint8_t* owner;
    int signer;
    int writable;
} msSolHostSystemAccount;

static const uint8_t msSolHostSystemProgram[32] = {0};

static uint64_t msSolHostRefuses(const char* text) {
    msSolHostFault(MS_SOL_HOST_REFUSED, text);
    return MS_SOL_HOST_REFUSED;
}

static int msSolHostSystemOwns(const msSolHostSystemAccount* account) {
    return memcmp(account->owner, msSolHostSystemProgram, 32) == 0;
}

static uint64_t msSolHostSystemAllocate(msSolHostSystemAccount* account, uint64_t space) {
    if (!account->signer) return MS_SOL_HOST_MISSING_REQUIRED_SIGNATURE;
    if (account->space != 0 || !msSolHostSystemOwns(account)) return MS_SOL_HOST_SYSTEM_ALREADY_IN_USE;
    if (space > MS_SOL_HOST_SYSTEM_MAX_SPACE) return MS_SOL_HOST_SYSTEM_INVALID_DATA_LENGTH;
    if (!account->writable) {
        return msSolHostRefuses("ReadonlyDataModified: sol_invoke_signed: the System program sized an account the instruction does not pass writable");
    }
    account->space = space;
    return 0;
}

static uint64_t msSolHostSystemAssign(msSolHostSystemAccount* account, const uint8_t* owner) {
    if (memcmp(account->owner, owner, 32) == 0) return 0;
    if (!account->signer) return MS_SOL_HOST_MISSING_REQUIRED_SIGNATURE;
    if (!msSolHostSystemOwns(account) || !account->writable
        || msSolHostAnyByte(account->record + 88, 0, msSolHostLoadU64(account->record + 80))) {
        return msSolHostRefuses("ModifiedProgramId: sol_invoke_signed: the System program may not change the owner of this account");
    }
    account->owner = owner;
    return 0;
}

static uint64_t msSolHostSystemTransfer(msSolHostSystemAccount* from, msSolHostSystemAccount* to, uint64_t amount) {
    if (!from->signer) return MS_SOL_HOST_MISSING_REQUIRED_SIGNATURE;
    if (from->space != 0) return MS_SOL_HOST_INVALID_ARGUMENT;
    if (amount > from->lamports) return MS_SOL_HOST_SYSTEM_TOO_FEW_LAMPORTS;
    if (amount != 0 && !msSolHostSystemOwns(from)) {
        return msSolHostRefuses("ExternalAccountLamportSpend: sol_invoke_signed: the System program spent the lamports of an account it does not own");
    }
    if (!from->writable) {
        return msSolHostRefuses("ReadonlyLamportChange: sol_invoke_signed: the System program debits an account the instruction does not pass writable");
    }
    from->lamports -= amount;
    if (amount > UINT64_MAX - to->lamports) return MS_SOL_HOST_ARITHMETIC_OVERFLOW;
    if (!to->writable) {
        return msSolHostRefuses("ReadonlyLamportChange: sol_invoke_signed: the System program credits an account the instruction does not pass writable");
    }
    to->lamports += amount;
    return 0;
}

static uint64_t msSolHostSystem(const uint64_t* header) {
    static const uint64_t dataLength[14] = {[0] = 52, [1] = 36, [2] = 12, [8] = 12, [13] = 52};
    if (header[4] < 4) return MS_SOL_HOST_INVALID_INSTRUCTION_DATA;
    const uint8_t* data = (const uint8_t*)header[3];
    uint32_t tag;
    memcpy(&tag, data, 4);
    if (tag > 13 || dataLength[tag] == 0) return msSolHostNotSimulated("System", tag, MS_SOL_HOST_INVALID_INSTRUCTION_DATA);
    if (header[4] < dataLength[tag]) return MS_SOL_HOST_INVALID_INSTRUCTION_DATA;
    const uint64_t amount = tag == 1 ? 0 : msSolHostLoadU64(data + 4);
    msSolHostSystemAccount accounts[2];
    uint64_t count = 0;
    while (count < 2 && msSolHostRecordOf(header, count) != NULL) {
        uint8_t* record = msSolHostRecordOf(header, count);
        const uint8_t* meta = (const uint8_t*)(header[1] + count * 16);
        accounts[count++] = (msSolHostSystemAccount){
            record, msSolHostLamports(record), msSolHostLoadU64(record + 80), record + 40, meta[9] != 0, meta[8] != 0,
        };
    }
    if (count < (tag == 0 || tag == 2 || (tag == 13 && amount != 0) ? 2 : 1)) {
        return msSolHostRefuses("MissingAccount: sol_invoke_signed: the System program instruction names fewer accounts than it reads");
    }
    msSolHostSystemAccount* first = &accounts[0];
    msSolHostSystemAccount* second = count == 2 && accounts[1].record != first->record ? &accounts[1] : first;
    uint64_t status = 0;
    switch (tag) {
    case 0:
        if (second->lamports != 0) return MS_SOL_HOST_SYSTEM_ALREADY_IN_USE;
        status = msSolHostSystemAllocate(second, msSolHostLoadU64(data + 12));
        if (status == 0) status = msSolHostSystemAssign(second, data + 20);
        if (status == 0) status = msSolHostSystemTransfer(first, second, amount);
        break;
    case 13:
        status = msSolHostSystemAllocate(first, msSolHostLoadU64(data + 12));
        if (status == 0) status = msSolHostSystemAssign(first, data + 20);
        if (status == 0 && amount != 0) status = msSolHostSystemTransfer(second, first, amount);
        break;
    case 1: status = msSolHostSystemAssign(first, data + 4); break;
    case 2: status = msSolHostSystemTransfer(first, second, amount); break;
    default: status = msSolHostSystemAllocate(first, amount); break;
    }
    if (status == 0) status = msSolHostResize(first->record, first->space);
    if (status == 0) status = msSolHostResize(second->record, second->space);
    if (status != 0) return status;
    for (msSolHostSystemAccount* account = first; ; account = second) {
        msSolHostSetLamports(account->record, account->lamports);
        memmove(account->record + 40, account->owner, 32);
        if (account == second) return 0;
    }
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
    msSolHostReturnLength = 0;
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

static uint64_t msSolHostSysvarStatus;

void msSolHostSetSysvarStatus(uint64_t status) { msSolHostSysvarStatus = status; }

uint64_t msSolHostGetClock(uint64_t out) {
    if (msSolHostSysvarStatus != 0) return msSolHostSysvarStatus;
    memcpy((void*)out, msSolHostClock, sizeof(msSolHostClock));
    return 0;
}

uint64_t msSolHostGetRent(uint64_t out) {
    msSolHostRentReadCount++;
    if (msSolHostSysvarStatus != 0) return msSolHostSysvarStatus;
    uint8_t* rent = (uint8_t*)out;
    uint64_t lamportsPerByteYear = MS_SOL_HOST_LAMPORTS_PER_BYTE_YEAR;
    double exemptionThreshold = MS_SOL_HOST_RENT_EXEMPTION_YEARS;
    memset(rent, 0, 17);
    memcpy(rent, &lamportsPerByteYear, 8);
    memcpy(rent + 8, &exemptionThreshold, 8);
    rent[16] = 50;
    return 0;
}

void msSolHostSetReturnData(const uint8_t* data, int64_t length) {
    if (msSolHostFaultCode != 0) return;
    if (length < 0 || length > MS_SOL_MAX_RETURN_DATA) {
        msSolHostFault(MS_SOL_HOST_REFUSED, "ProgramFailedToComplete: sol_set_return_data: Return data too large, more than 1024 bytes");
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
