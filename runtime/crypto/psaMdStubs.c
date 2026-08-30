/* Weak fallbacks for the three psa_util.c symbols that md.c references.
 *
 * Why this file exists — a COFF/ELF linker difference, not an mbedTLS bug:
 *
 * md.c *defines* mbedtls_md_error_from_psa() under MBEDTLS_PSA_CRYPTO_CLIENT
 * (always on in tf-psa-crypto 4.x), but every *call* to it is under
 * MBEDTLS_MD_SOME_PSA — which is off here, because every hash we use is
 * built-in and no PSA accelerator driver is configured. So md.o carries a
 * defined-but-never-called function whose body references psa_util.c.
 *
 * ELF hides this: -ffunction-sections + --gc-sections drops the dead function
 * along with its relocations, so std/crypto links without psa_util.o. LLD's
 * COFF driver resolves symbols *before* section GC, so the same object fails
 * with three undefined symbols. Verified: no linker flag changes this —
 * --gc-sections is accepted but ineffective, /OPT:REF is rejected by the zig
 * driver, and both spellings still error.
 *
 * Pulling psa_util.c into std/crypto is not an option: it also holds
 * mbedtls_psa_get_random (-> psa_generate_random -> psa_crypto.c) and the
 * ECDSA DER converters (-> asn1{parse,write}.c -> bignum.c). Measured with a
 * symbol-closure pass over the built objects, that turns std/crypto's 9-file
 * list into 54 — the whole PSA/TLS stack — for a program that only hashes.
 *
 * So: define the three weakly here. std/crypto compiles this file; when
 * std/crypto/tls is alive it compiles the real psa_util.c, whose strong
 * definitions override these regardless of link order (verified on both
 * lld-link and ld.lld). Nothing calls these at runtime in either build — the
 * only consumer is the dead function above — so the stub bodies exist purely
 * to satisfy symbol resolution.
 *
 * Types are spelled out locally rather than pulled from psa_util_internal.h,
 * matching runtime/crypto/tls/psaTlsStubs.c, so this file stays independent of
 * the mbedTLS config. They must keep matching:
 *   psa_util_internal.h  mbedtls_error_pair_t { int16_t psa_status; int16_t mbedtls_error; }
 *   psa_util_internal.h  extern const mbedtls_error_pair_t psa_to_md_errors[4];
 */
#include <stdint.h>
#include <stddef.h>

typedef int32_t psa_status_t;

typedef struct {
	int16_t psa_status;
	int16_t mbedtls_error;
} mbedtls_error_pair_t;

#define MBEDTLS_ERR_ERROR_GENERIC_ERROR ((int)-0x0001)

__attribute__((weak))
const mbedtls_error_pair_t psa_to_md_errors[4] = {
	{ 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 },
};

__attribute__((weak))
int psa_generic_status_to_mbedtls(psa_status_t status)
{
	(void)status;
	return MBEDTLS_ERR_ERROR_GENERIC_ERROR;
}

__attribute__((weak))
int psa_status_to_mbedtls(psa_status_t status,
                          const mbedtls_error_pair_t *local_translations,
                          size_t local_errors_num,
                          int (*fallback_f)(psa_status_t))
{
	(void)local_translations;
	(void)local_errors_num;
	if (fallback_f != NULL) {
		return fallback_f(status);
	}
	return MBEDTLS_ERR_ERROR_GENERIC_ERROR;
}
