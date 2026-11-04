#ifndef MS_CRYPTO_ARGON2_ORACLE_H
#define MS_CRYPTO_ARGON2_ORACLE_H

#include "runtime/core/string.h"
#include <stdint.h>

msString msArgon2OracleRaw(msString password, msString salt, msString secret, msString ad,
                           int32_t mode, int32_t timeCost, int32_t memoryCost,
                           int32_t parallelism, int32_t hashLen);
msString msArgon2OracleEncoded(msString password, msString salt, int32_t mode,
                               int32_t timeCost, int32_t memoryCost, int32_t parallelism,
                               int32_t hashLen);
int32_t msArgon2OracleVerify(msString encoded, msString password, int32_t mode);

#endif
