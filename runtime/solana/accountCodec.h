#ifndef MS_SOLANA_ACCOUNT_CODEC_H
#define MS_SOLANA_ACCOUNT_CODEC_H

#include <stdint.h>

static inline float msSolAccountFloat32FromBits(uint32_t bits) {
    float value;
    __builtin_memcpy(&value, &bits, sizeof value);
    return value;
}

static inline double msSolAccountFloat64FromBits(uint64_t bits) {
    double value;
    __builtin_memcpy(&value, &bits, sizeof value);
    return value;
}

static inline uint32_t msSolAccountFloat32Bits(float value) {
    uint32_t bits;
    __builtin_memcpy(&bits, &value, sizeof bits);
    return bits;
}

static inline uint64_t msSolAccountFloat64Bits(double value) {
    uint64_t bits;
    __builtin_memcpy(&bits, &value, sizeof bits);
    return bits;
}

#endif
