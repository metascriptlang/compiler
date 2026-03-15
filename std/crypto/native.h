#ifndef STD_CRYPTO_NATIVE_H
#define STD_CRYPTO_NATIVE_H

#include "std/core/string/native.h"

// --- Hash ---
msString msCryptoHash(msString algorithm, msString data, msString encoding);
msString msCryptoHmac(msString algorithm, msString key, msString data, msString encoding);

// --- Random ---
msString msCryptoRandomBytes(int32_t size);
int32_t  msCryptoRandomInt(int32_t min, int32_t max);
msString msCryptoRandomUUID(void);

// --- Key Derivation ---
msString msCryptoPbkdf2(msString password, msString salt, int32_t iterations, int32_t keyLength, msString digest);
msString msCryptoHkdf(msString algorithm, msString ikm, msString salt, msString info, int32_t length);

// --- Encoding ---
msString msCryptoToHex(msString data);
msString msCryptoFromHex(msString hex);
msString msCryptoToBase64(msString data);
msString msCryptoFromBase64(msString b64);

// --- Timing-Safe ---
double msCryptoTimingSafeEqual(msString a, msString b);

// --- Init ---
double msCryptoInit(void);
void   msCryptoCleanup(void);

#endif
