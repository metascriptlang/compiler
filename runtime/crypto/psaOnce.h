#ifndef MS_PSA_ONCE_H
#define MS_PSA_ONCE_H

/* One lock and one init for every PSA user in the process (rsa.c, tls.c): MBEDTLS_THREADING_C is
 * off, so PSA key-slot and RNG state is not thread-safe and each caller holds this lock around
 * every PSA call, directly or through PK, X.509 and SSL. */
void msPsaLock(void);
void msPsaUnlock(void);
/* Call with the lock held; 0 once PSA is initialised, -1 when psa_crypto_init failed. */
int msPsaEnsure(void);

#endif
