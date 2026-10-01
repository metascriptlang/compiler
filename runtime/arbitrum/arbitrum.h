#ifndef MS_ARBITRUM_H
#define MS_ARBITRUM_H

#include <stdint.h>

#if !defined(__wasm32__) || !defined(MSOS_BARE) || !defined(MSGC_MANUAL)
#error "std/arbitrum requires --os=bare --cpu=wasm32 --gc=manual"
#endif

uint32_t msArbCalldataAddress(void);
uint32_t msArbCalldataLength(void);
uint32_t msArbScratch(void);
uint32_t msArbAllocate(uint32_t length);
void msArbSetResult(uint32_t address, uint32_t length, int32_t status);
void msArbStorageLoad(uint32_t key, uint32_t destination);
void msArbStorageStore(uint32_t key, uint32_t value);
void msArbMsgSender(uint32_t destination);
void msArbContractAddress(uint32_t destination);
void msArbMsgValue(uint32_t destination);

static inline uint8_t msArbLoadByte(uint32_t address) {
    return *(const uint8_t*)(uintptr_t)address;
}

static inline void msArbStoreByte(uint32_t address, uint8_t value) {
    *(uint8_t*)(uintptr_t)address = value;
}

#endif
