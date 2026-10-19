#ifndef MSOS_SOLANA

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "runtime/solana/solana.h"

#define MS_SOL_HOST_REFUSED UINT64_MAX

static uint64_t msSolHostFaultCode;
static char msSolHostFaultText[160];

static void msSolHostFault(uint64_t result, const char* text) {
    if (msSolHostFaultCode != 0) return;
    msSolHostFaultCode = result;
    snprintf(msSolHostFaultText, sizeof(msSolHostFaultText), "%s", text);
}

void msSolHostClearFault(void) {
    msSolHostFaultCode = 0;
    msSolHostFaultText[0] = 0;
}

uint64_t msSolHostFaultCodeOf(void) { return msSolHostFaultCode; }
msString msSolHostFaultMessage(void) { return msStringNew(msSolHostFaultText, (int64_t)strlen(msSolHostFaultText)); }

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

void msSolHostRaise(uint64_t code, msString text) {
    char line[256];
    snprintf(line, sizeof(line), "%.*s", (int)text.len, text.p == NULL ? "" : (const char*)text.p->data);
    msSolHostFault(code, line);
}

#endif
