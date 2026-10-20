#ifndef MSOS_SOLANA

#include <stdint.h>

#include "runtime/solana/solana.h"

uint64_t msSolHostReset(uint64_t input);
void msSolHostResetSimulator(void);
void msSolHostResetDispatcher(void);
void msSolHostHoldAccounts(uint64_t table, uint64_t count);
void msSolHostSettle(void);
void msSolHostSetReturnDataAt(uint64_t data, uint64_t length);

void msSolHostEnter(uint64_t input) {
    msSolHostResetSimulator();
    msSolHostResetDispatcher();
    uint64_t accounts = msSolHostReset(input);
    msSolHostHoldAccounts(accounts, msSolHostContext()->accountCount);
}

void msSolHostLeave(void) {
    if (msSolHostResult() != 0) return;
    msSolHostSettle();
}

void msSolHostSetReturnData(const uint8_t* data, int64_t length) {
    msSolHostSetReturnDataAt((uint64_t)data, (uint64_t)length);
}

#endif
