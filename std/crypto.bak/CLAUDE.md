# std/crypto — Cryptographic Module Implementation Plan

## Goal

Feature-complete crypto module for MetaScript, ported from the reference implementation at `~/projects/metascript/std/crypto/`. Backed by mbedTLS (C runtime), with pure MS wrappers and `Result<T, CryptoError>` error handling throughout.

---

## Research Findings

### Three Crypto Sources Compared

| Aspect | Zig (our `vendor/zig`) | HashLink (our `vendor/hashlink`) | Reference (`~/projects/metascript`) |
|--------|----------------------|--------------------------------|--------------------------------------|
| **Library** | Pure Zig stdlib | mbedTLS **3.6.1** | mbedTLS **4.0.0** |
| **Language** | 100% Zig (no C) | C library (108 .c files) | C library (30 .c in `library/`, rest in `tf-psa-crypto/`) |
| **API style** | Zig generics | C (legacy MD + PSA) | C (legacy MD + PSA) |
| **Size** | 85 .zig files | Full build (all features) | Minimal build (72KB `.a`) |
| **TLS** | `tls/Client.zig` | Full SSL/TLS stack | X.509 stubs only |
| **Usable by us** | No (Zig ABI) | **Yes** (C ABI, headers available) | **Yes** (C ABI, source available) |

### mbedTLS Version Decision: **4.0.0** (latest)

**Why 4.0.0:**
- **Matches reference project exactly** — reference vendors 4.0.0 and its `crypto.c` compiles cleanly against it
- **Future-proof** — 4.0.0 LTS ends 2027, starting on 4.0.0 avoids a forced migration
- **All APIs available** — hash, HMAC, AES, PK, PSA all work (verified in reference)
- **HMAC deprecation is a warning, not a blocker** — `mbedtls_md_hmac_*` deprecated in 4.0 but still compiles. We can migrate to `psa_mac_*` API at our leisure

**HMAC deprecation note**: From 4.0 onwards, `mbedtls_md_hmac_*` functions print deprecation warnings. The reference `crypto.c` still uses them successfully. When we migrate Phase 3 (PSA key gen), we can also migrate HMAC to `psa_mac_*` in the same pass. For Phase 1, suppress with `-Wno-deprecated-declarations` if needed.

**Directory structure**: 4.0.0 has a `tf-psa-crypto/` subdirectory split. The `library/` dir still exists for core crypto. Headers are at `include/mbedtls/` and `tf-psa-crypto/drivers/builtin/include/` (or `include/psa/`).

**Decision**: Vendor mbedTLS 4.0.0 under `vendor/mbedtls/`. Download from GitHub releases. Match the reference project version exactly.

### What the Reference `crypto.c` Actually Calls

**Legacy MD API** (hashing + HMAC — 90% of the code):
```
mbedtls_md_init, mbedtls_md_setup, mbedtls_md_starts, mbedtls_md_update,
mbedtls_md_finish, mbedtls_md_free, mbedtls_md_info_from_type,
mbedtls_md_get_size, mbedtls_md_hmac_starts, mbedtls_md_hmac_update,
mbedtls_md_hmac_finish, mbedtls_md_type_t, mbedtls_md_info_t
```

**AES API** (encryption — direct, not via cipher API):
```
mbedtls_aes_init, mbedtls_aes_setkey_enc, mbedtls_aes_setkey_dec,
mbedtls_aes_crypt_cbc, mbedtls_aes_crypt_ecb, mbedtls_aes_free,
mbedtls_aes_context
```

**PK API** (RSA/EC key management):
```
mbedtls_pk_init, mbedtls_pk_free, mbedtls_pk_parse_key,
mbedtls_pk_parse_public_key, mbedtls_pk_sign, mbedtls_pk_verify,
mbedtls_pk_write_key_pem, mbedtls_pk_write_pubkey_pem,
mbedtls_pk_get_bitlen
```

**PSA API** (RSA/EC key generation only):
```
psa_crypto_init, psa_generate_key, psa_destroy_key,
psa_set_key_usage_flags, psa_set_key_algorithm, psa_set_key_type,
psa_set_key_bits, psa_key_attributes_t, mbedtls_svc_key_id_t,
mbedtls_pk_copy_from_psa, mbedtls_pk_get_psa_attributes,
mbedtls_pk_import_into_psa
```

**Platform**:
```
mbedtls_platform_util.h (mbedtls_platform_zeroize)
```

**NOT used** (from reference `crypto.c`):
- `cipher.h` API — reference implements GCM manually using AES ECB + GHASH
- `hkdf.h` — reference implements HKDF manually using MD HMAC
- `pkcs5.h` — reference implements PBKDF2 manually using MD HMAC
- `chachapoly.h` — referenced but behind `#ifdef` that may not be active
- `x509_crt.h` — all X.509 functions are stubs (return NULL)

### Key Adaptation Points

#### 1. No `Buffer` Type — Use `string`

Our runtime has `msString` but no `msBuffer` or `msOptionalString`. The reference uses `Buffer` (imported from `std/buffer`) for binary data.

**Our approach**: Use `string` for all binary data (like `std/fs` does). At the C level, `msString` can hold arbitrary bytes. The MS layer wraps with `Result<string, CryptoError>`.

| Reference API | Our API |
|---------------|---------|
| `hash(algo, data): Result<string, E>` | Same |
| `hashBuffer(algo, data): Result<Buffer, E>` | Drop — `hash` returns hex/base64 string |
| `randomBytes(n): Result<Buffer, E>` | `randomBytes(n): Result<string, E>` (raw bytes as string) |
| `encrypt(algo, key: Buffer, ...)` | `encrypt(algo, key: string, ...)` |
| `hmacBuffer(algo, key, data): Buffer` | Drop — `hmac` returns hex/base64 string |

#### 2. No Optional Params (`?:`) — Use Overloads or Defaults

Reference uses `options?: HashOptions`. Our checker may not handle optional interface fields.

**Our approach**: Default encoding to `"hex"` inside the C wrapper. No options struct needed for basic use. Advanced users call the full-params version.

#### 3. `msOptionalString` → `MS_EMPTY_STRING` Pattern

Our runtime uses `MS_EMPTY_STRING` for "no result" (same as `std/fs`). The MS layer checks `result.length === 0` for failure.

#### 4. Class Support

Reference uses `class Hasher`, `class RsaKeyPair`, etc. Our compiler supports `class` (done in types.ms migration). However, `private constructor`, `static` methods, and `get` properties need verification.

**Phase 1 approach**: Use functions + opaque `int32` handles (like fd in std/net) instead of classes. Migrate to classes in Phase 2 when verified.

#### 5. `@link` / `@passC` / `@compile` Directives

Our compiler supports all three:
- `@include("path")` — emits `#include` (used by std/fs, std/net, std/io)
- `@passC("flags")` — appends to compiler flags (stored in `CheckerContext.compilerFlags`)
- `@link("path.a")` / `@passL("flags")` — appends to linker flags (stored in `CheckerContext.linkFlags`)
- `@compile("file.c")` — compiles additional C source (handled in `compile.ms:processCompileDirectives`)

---

## Architecture

```
User Code
    |
    v
std/crypto/index.cms      (C-backend prelude: extern + MS wrappers)
std/crypto/index.ms        (interface contract: throw stubs)
std/crypto/errors.ms       (error types, shared across backends)
    |
    v
std/crypto/native.h        (thin C header — our function signatures)
std/crypto/crypto.c         (C implementation — mbedTLS calls)
    |
    v
vendor/mbedtls/             (mbedTLS 4.0.0 source tree)
```

### Differences from Reference Architecture

| Reference | Ours | Reason |
|-----------|------|--------|
| `crypto.h` (903 LOC, all decls) | `native.h` (~200 LOC, essential decls) | Convention: `native.h` like std/fs, std/net |
| `crypto.c` (2043 LOC, monolith) | `crypto.c` (~1200 LOC, no RSA/EC/X.509 in Phase 1) | Phased: hash+HMAC+random first |
| `index.cms` uses `Buffer` type | `index.cms` uses `string` | No `std/buffer` in our compiler |
| `utils.ms` (pure MS hex/base64) | Inline in `native.h` / `crypto.c` | C-level encoding is faster and simpler |
| Classes (`Hasher`, `RsaKeyPair`) | Functions + handles (Phase 1), classes (Phase 2) | Verify class codegen first |

---

## File Plan

### Phase 1: Core (Hash + HMAC + Random + Encoding)

```
vendor/mbedtls/              mbedTLS 4.0.0 source (git submodule or tarball)

std/crypto/
  CLAUDE.md                  this file
  errors.ms          ~80 LOC  error types (pure MS, from reference)
  native.h          ~150 LOC  C function declarations
  crypto.c          ~800 LOC  C implementation (hash, HMAC, random, PBKDF2, encoding)
  index.cms         ~250 LOC  C-backend prelude (MS wrappers)
  index.ms          ~100 LOC  interface contract (throw stubs for non-C backends)
```

**Phase 1 total: ~1380 LOC** (plus vendored mbedTLS)

### Phase 2: Symmetric Encryption (AES-CBC/GCM, ChaCha20-Poly1305)

Add ~400 LOC to `crypto.c` and ~150 LOC to `index.cms`.

### Phase 3: Asymmetric Crypto (RSA, ECDSA, ECDH) + Streaming

Add ~500 LOC to `crypto.c`, ~300 LOC to `index.cms`. Requires PSA init.

### Phase 4: X.509 Certificates (Future)

Currently stubs in the reference. Implement when TLS support is needed.

---

## Phase 1 Detailed Design

### `std/crypto/errors.ms` (~80 LOC)

Ported from reference `errors.ms`, adapted to our enum syntax:

```ms
export enum CryptoErrorKind {
    InvalidAlgorithm,
    InvalidKey,
    InvalidInput,
    InvalidEncoding,
    HashFailed,
    HmacFailed,
    RandomFailed,
    EncryptionFailed,
    DecryptionFailed,
    KeyDerivationFailed,
    AuthenticationFailed,
    KeyGenerationFailed,
    SignatureFailed,
    VerificationFailed,
    CertificateError,
}

export interface CryptoError {
    kind: CryptoErrorKind;
    operation: string;
    message: string;
}

export function cryptoError(kind: CryptoErrorKind, operation: string, message: string): CryptoError {
    return { kind: kind, operation: operation, message: message };
}

// Convenience constructors (same names as reference)
export function hashFailed(algorithm: string, reason: string): CryptoError { ... }
export function hmacFailed(algorithm: string, reason: string): CryptoError { ... }
export function randomFailed(reason: string): CryptoError { ... }
export function invalidAlgorithm(algorithm: string): CryptoError { ... }
export function invalidKey(operation: string, reason: string): CryptoError { ... }
export function invalidInput(operation: string, reason: string): CryptoError { ... }
export function keyDerivationFailed(algorithm: string, reason: string): CryptoError { ... }

// Classification helpers
export function isRetryable(e: CryptoError): boolean { return e.kind === CryptoErrorKind.RandomFailed; }
```

**Key difference from reference**: Use `enum CryptoErrorKind` (C-style integers) instead of string union type `"HashFailed" | "HmacFailed" | ...`. Constructor names are lowercase (our convention: `hashFailed` not `HashFailed`).

### `std/crypto/native.h` (~150 LOC)

Thin header declaring C functions. Pattern matches `std/fs/native.h` and `std/net/native.h`.

```c
#ifndef STD_CRYPTO_NATIVE_H
#define STD_CRYPTO_NATIVE_H

#include "../../runtime/core/string.h"

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
```

**Key design decisions**:
- Returns `msString` (empty on failure) — same pattern as `std/fs`
- Uses `int32_t` for sizes — our sized integer convention
- Uses `double` for booleans — same as `std/fs` (`1.0` = true, `0.0` = false)
- Names use `msCrypto` prefix + PascalCase method (our convention)
- **No Buffer type** — `msString` holds binary data (same underlying bytes)
- **No `msOptionalString`** — return `MS_EMPTY_STRING` on failure

### `std/crypto/crypto.c` (~800 LOC for Phase 1)

Ported from reference `crypto.c`, adapted:

**What to keep from reference**:
1. Legacy MD API usage for hashing and HMAC (lines 1-600) — clean, well-tested
2. Hex and base64 encoding (internal, `encode_to_hex`, `encode_to_base64`)
3. Random byte generation via `arc4random_buf` on macOS / `getrandom` on Linux
4. PBKDF2 manual implementation using MD HMAC (avoids pkcs5.h dependency)
5. HKDF manual implementation using MD HMAC (avoids hkdf.h dependency)
6. Algorithm string → `mbedtls_md_type_t` mapping
7. UUID v4 formatting

**What to change**:
1. Use `msCStr()` instead of `ms_string_cstr()` (our runtime name)
2. Use `msStringNew()` instead of `ms_string_new()` (our runtime name)
3. Use `MS_EMPTY_STRING` instead of `MS_OPTIONAL_STRING_NONE` (no optional type)
4. Remove all `msBuffer` references — use `msString` everywhere
5. Remove `msOptionalString` — return `msString` (empty = failure)
6. Prefix functions with `msCrypto` not `ms_crypto_`
7. Use `int32_t` params where reference uses `double` or `uint32_t`

**What to drop (Phase 1)**:
1. Streaming hash/HMAC contexts (`Hasher`, `Hmac` classes) — Phase 2
2. AES encryption/decryption — Phase 2
3. ChaCha20-Poly1305 — Phase 2
4. RSA key generation/signing — Phase 3
5. EC key generation/signing/ECDH — Phase 3
6. X.509 certificate parsing — Phase 4

**mbedTLS modules needed (Phase 1)**:
- `md.c` + hash impls (`sha256.c`, `sha512.c`, `sha1.c`, `md5.c`)
- `platform_util.c` (for `mbedtls_platform_zeroize`)
- No PSA, no PK, no cipher, no entropy, no ctr_drbg

**Random number generation** (no mbedTLS needed):
- macOS: `arc4random_buf()` (in `<stdlib.h>`, always available)
- Linux: `getrandom()` (in `<sys/random.h>`, kernel 3.17+)
- Fallback: `/dev/urandom`

### `std/crypto/index.cms` (~250 LOC)

C-backend prelude with extern declarations and MS wrappers:

```ms
@include("crypto/native.h");
@compile("crypto/crypto.c");
@passC("-I../../vendor/mbedtls/include");
@passC("-I../../vendor/mbedtls/library");

// C bindings
extern function msCryptoInit(): number;
extern function msCryptoHash(algorithm: string, data: string, encoding: string): string;
extern function msCryptoHmac(algorithm: string, key: string, data: string, encoding: string): string;
extern function msCryptoRandomBytes(size: int32): string;
extern function msCryptoRandomInt(min: int32, max: int32): int32;
extern function msCryptoRandomUUID(): string;
extern function msCryptoPbkdf2(password: string, salt: string, iterations: int32, keyLength: int32, digest: string): string;
extern function msCryptoHkdf(algorithm: string, ikm: string, salt: string, info: string, length: int32): string;
extern function msCryptoToHex(data: string): string;
extern function msCryptoFromHex(hex: string): string;
extern function msCryptoToBase64(data: string): string;
extern function msCryptoFromBase64(b64: string): string;
extern function msCryptoTimingSafeEqual(a: string, b: string): number;

import { CryptoError, CryptoErrorKind, cryptoError, hashFailed, hmacFailed, randomFailed, invalidAlgorithm, keyDerivationFailed } from "./errors";

// Re-export errors
export type { CryptoError, CryptoErrorKind } from "./errors";

// --- Hash Functions ---

export function sha256(data: string, encoding: string): Result<string, CryptoError> {
    return hash("sha256", data, encoding);
}

export function sha512(data: string, encoding: string): Result<string, CryptoError> {
    return hash("sha512", data, encoding);
}

export function sha1(data: string, encoding: string): Result<string, CryptoError> {
    return hash("sha1", data, encoding);
}

export function md5(data: string, encoding: string): Result<string, CryptoError> {
    return hash("md5", data, encoding);
}

export function hash(algorithm: string, data: string, encoding: string): Result<string, CryptoError> {
    if (encoding === "") encoding = "hex";
    const result = msCryptoHash(algorithm, data, encoding);
    if (result.length === 0) return Result.err(hashFailed(algorithm, "hash computation failed"));
    return Result.ok(result);
}

// --- HMAC ---

export function hmac(algorithm: string, key: string, data: string, encoding: string): Result<string, CryptoError> {
    if (encoding === "") encoding = "hex";
    const result = msCryptoHmac(algorithm, key, data, encoding);
    if (result.length === 0) return Result.err(hmacFailed(algorithm, "HMAC computation failed"));
    return Result.ok(result);
}

// --- Random ---

export function randomBytes(size: int32): Result<string, CryptoError> {
    const result = msCryptoRandomBytes(size);
    if (result.length === 0) return Result.err(randomFailed("random byte generation failed"));
    return Result.ok(result);
}

export function randomInt(min: int32, max: int32): Result<int32, CryptoError> {
    // Validate range
    if (min >= max) return Result.err(cryptoError(CryptoErrorKind.InvalidInput, "randomInt", "min must be less than max"));
    return Result.ok(msCryptoRandomInt(min, max));
}

export function randomUUID(): Result<string, CryptoError> {
    const result = msCryptoRandomUUID();
    if (result.length === 0) return Result.err(randomFailed("UUID generation failed"));
    return Result.ok(result);
}

// --- Key Derivation ---

export function pbkdf2(password: string, salt: string, iterations: int32, keyLength: int32, digest: string): Result<string, CryptoError> {
    if (digest === "") digest = "sha256";
    const result = msCryptoPbkdf2(password, salt, iterations, keyLength, digest);
    if (result.length === 0) return Result.err(keyDerivationFailed("pbkdf2", "key derivation failed"));
    return Result.ok(result);
}

export function hkdf(algorithm: string, ikm: string, salt: string, info: string, length: int32): Result<string, CryptoError> {
    if (algorithm === "") algorithm = "sha256";
    const result = msCryptoHkdf(algorithm, ikm, salt, info, length);
    if (result.length === 0) return Result.err(keyDerivationFailed("hkdf", "key derivation failed"));
    return Result.ok(result);
}

// --- Encoding ---

export function toHex(data: string): string { return msCryptoToHex(data); }
export function fromHex(hex: string): string { return msCryptoFromHex(hex); }
export function toBase64(data: string): string { return msCryptoToBase64(data); }
export function fromBase64(b64: string): string { return msCryptoFromBase64(b64); }

// --- Timing-Safe ---

export function timingSafeEqual(a: string, b: string): boolean {
    return msCryptoTimingSafeEqual(a, b) === 1;
}
```

### `std/crypto/index.ms` (~100 LOC)

Interface contract for non-C backends (throw stubs). Same pattern as reference `index.ms`.

---

## mbedTLS Vendoring Strategy

**DONE**: Git submodule at `vendor/mbedtls/` (tag `mbedtls-4.0.0`), with `tf-psa-crypto` submodule initialized.

```bash
git submodule add https://github.com/Mbed-TLS/mbedtls.git vendor/mbedtls
cd vendor/mbedtls && git checkout mbedtls-4.0.0
git submodule update --init tf-psa-crypto
```

### Build Integration: `@compile` Directives (no separate build step)

Each mbedTLS `.c` file is compiled via `@compile()` in `index.cms`. Ccache caches results.
PSA stubs (`psa_stubs.c`) avoid linking full PSA crypto layer for Phase 1.

### Required .c Files by Phase

**Phase 1** (hash + HMAC + random) — **DONE**:
```
tf-psa-crypto/drivers/builtin/src/md.c
tf-psa-crypto/drivers/builtin/src/sha256.c
tf-psa-crypto/drivers/builtin/src/sha512.c
tf-psa-crypto/drivers/builtin/src/sha1.c
tf-psa-crypto/drivers/builtin/src/md5.c
tf-psa-crypto/drivers/builtin/src/sha3.c
tf-psa-crypto/drivers/builtin/src/ripemd160.c
tf-psa-crypto/drivers/builtin/src/platform_util.c
+ psa_stubs.c (custom — stubs PSA error conversion)
```
8 mbedTLS files + 1 stub.

**Phase 2** (encryption):
```
library/aes.c
library/constant_time.c
```
+2 files (GCM and PKCS7 padding are hand-implemented in our crypto.c, matching reference).

**Phase 3** (asymmetric):
```
library/pk.c
library/pk_wrap.c
library/pem.c
library/asn1parse.c
library/asn1write.c
library/bignum.c
library/bignum_core.c
library/rsa.c
library/ecdsa.c
library/ecdh.c
library/ecp.c
library/ecp_curves.c
library/base64.c
library/oid.c
library/entropy.c
library/ctr_drbg.c
library/psa_crypto.c      # For key generation
library/psa_crypto_hash.c
library/psa_crypto_slot_management.c
```
+18 files.

### Build Integration — DONE

Uses `@compile` directives (Approach A from initial plan). Each mbedTLS `.c` file compiled individually. Ccache makes this fast.

**Important path notes**:
- `@compile()` paths are resolved relative to the module directory (`std/crypto/`)
- `@passC()` flags are passed as-is to `cc` which runs from the **project root**
- Therefore `@compile("../../vendor/...")` works (resolved by compiler), but `@passC("-I../../vendor/...")` does NOT (resolved by cc from project root)
- Use `@passC("-Ivendor/...")` (relative to project root) for include flags

**Required include paths** (all in `@passC` in `index.cms`):
```
-Ivendor/mbedtls/tf-psa-crypto/include          # md.h, pk.h, psa/
-Ivendor/mbedtls/tf-psa-crypto/drivers/builtin/include  # private headers
-Ivendor/mbedtls/tf-psa-crypto/drivers/builtin/src      # internal headers
-Ivendor/mbedtls/tf-psa-crypto/core              # tf_psa_crypto_common.h
-Ivendor/mbedtls/include                          # top-level headers
-Wno-deprecated-declarations                       # suppress HMAC deprecation
```

---

## API Comparison: Reference vs Ours

### Hash Functions

| Reference | Ours | Notes |
|-----------|------|-------|
| `sha256(data, options?): Result<string, E>` | `sha256(data, encoding): Result<string, E>` | No optional params; encoding defaults to "hex" if "" |
| `hash(algo, data, options?): Result<string, E>` | `hash(algo, data, encoding): Result<string, E>` | Same |
| `hashBuffer(algo, data): Result<Buffer, E>` | Dropped | Use `hash(algo, data, "binary")` for raw bytes |
| `createHash(algo): Hasher` | Phase 2 | Streaming hash |

### HMAC

| Reference | Ours |
|-----------|------|
| `hmac(algo, key, data, options?): Result<string, E>` | `hmac(algo, key, data, encoding): Result<string, E>` |
| `hmacBuffer(algo, key, data): Result<Buffer, E>` | Dropped |
| `createHmac(algo, key): Hmac` | Phase 2 |

### Random

| Reference | Ours |
|-----------|------|
| `randomBytes(size): Result<Buffer, E>` | `randomBytes(size): Result<string, E>` |
| `randomInt(min, max): Result<number, E>` | `randomInt(min, max): Result<int32, E>` |
| `randomUUID(): Result<string, E>` | Same |
| `randomFill(buffer): Result<Buffer, E>` | Dropped (use randomBytes) |

### Key Derivation

| Reference | Ours |
|-----------|------|
| `pbkdf2Sync(pwd, salt, options?): Result<Buffer, E>` | `pbkdf2(pwd, salt, iters, keyLen, digest): Result<string, E>` |
| `hkdf(algo, ikm, len, options?): Result<Buffer, E>` | `hkdf(algo, ikm, salt, info, len): Result<string, E>` |
| `hkdfExtract / hkdfExpand` | Phase 2 |

### Encoding

| Reference | Ours |
|-----------|------|
| `bufferToHex / hexToBuffer` (in utils.ms, pure MS) | `toHex / fromHex` (C-level, faster) |
| `bufferToBase64` (in utils.ms, pure MS) | `toBase64 / fromBase64` (C-level, faster) |

### Timing-Safe

| Reference | Ours |
|-----------|------|
| `timingSafeEqual(a, b): boolean` | Same |

---

## Implementation Order — Phase 1 DONE

| Step | File | Status |
|------|------|--------|
| 0 | Vendor mbedTLS 4.0.0 (git submodule) | DONE |
| 1 | `errors.ms` — CryptoErrorKind enum, CryptoError interface | DONE |
| 2 | `native.h` — C function declarations | DONE |
| 3 | `psa_stubs.c` — PSA error conversion stubs | DONE |
| 4 | `crypto.c` — C implementation (hash, HMAC, random, PBKDF2, HKDF, encoding) | DONE |
| 5 | `index.cms` — C-backend prelude (extern + MS wrappers) | DONE |
| 6 | `test.ms` — 25 tests (all pass) | DONE |

### Test Plan (Phase 1)

Inline tests in `index.cms` or a separate `test.ms`:

**Hash tests** (~10):
- SHA-256 of "" = known value (`e3b0c44298fc1c...`)
- SHA-256 of "hello" = known value
- SHA-512 of "hello" = known value
- SHA-1 of "hello" = known value
- MD5 of "hello" = known value
- Hash with base64 encoding
- Invalid algorithm returns error

**HMAC tests** (~5):
- HMAC-SHA256 with known key/data = known value (RFC 4231 test vectors)
- HMAC with different algorithms
- Empty key/data edge cases

**Random tests** (~5):
- randomBytes returns correct length
- randomBytes returns different values on successive calls
- randomInt range check
- randomUUID format (8-4-4-4-12, version 4 marker)

**KDF tests** (~4):
- PBKDF2 with known vectors (RFC 6070)
- HKDF with known vectors (RFC 5869)

**Encoding tests** (~6):
- Hex encode/decode roundtrip
- Base64 encode/decode roundtrip
- Known encoding values

**Timing-safe tests** (~3):
- Equal strings return true
- Different strings return false
- Different lengths return false

---

## Key Discoveries

### `.length` is UTF-8 Character Count, Not Byte Count

`msStringLength()` counts Unicode code points, not bytes. For binary data (randomBytes, PBKDF2, HKDF output), `.length` returns fewer characters than the byte count because random bytes may look like multi-byte UTF-8 sequences.

**Workaround**: Always hex-encode binary data before checking length. `toHex(data).length / 2` gives the true byte count.

### `msStringNewCap` + Manual `.len` Mutation Doesn't Work

DRC may copy the struct, losing manual `.len` changes. Always use `msStringNew(buf, len)` to create strings with explicit length. Never use `msStringNewCap` + fill + set `.len` directly.

## Key Design Principles

1. **`string` everywhere** — no Buffer type, `msString` holds binary data natively
2. **`Result<T, CryptoError>` everywhere** — no exceptions, no panics
3. **`enum CryptoErrorKind`** — native C switch, exhaustive match
4. **`int32` for sizes** — proper sized integers, not f64
5. **Empty string = failure** at C level — MS wrapper converts to `Result.err`
6. **Pre-built static library** — `libmbedcrypto.a` built once, linked via `@link`
7. **Phase 1 = no PSA** — hash/HMAC/random don't need it. PSA only for Phase 3 key generation
8. **C-level encoding** — hex/base64 in C (not pure MS) for performance
9. **Lowercase constructors** — `hashFailed()` not `HashFailed()` (our error convention)
10. **Drop optional params** — use explicit args with empty-string defaults

---

## Future Phases

### Phase 2: Encryption + Streaming Hash (~550 LOC added)

- AES-128/256-CBC encryption/decryption
- AES-128/256-GCM authenticated encryption
- ChaCha20-Poly1305 AEAD
- Streaming `Hasher` / `Hmac` (if class codegen verified)
- HKDF extract/expand

### Phase 3: Asymmetric Crypto (~800 LOC added)

- RSA key generation (2048/3072/4096)
- RSA sign/verify (PSS)
- RSA encrypt/decrypt (OAEP)
- ECDSA sign/verify (P-256/P-384/P-521)
- ECDH key agreement
- PEM import/export
- Requires PSA crypto init

### Phase 4: X.509 + TLS Foundation

- X.509 certificate parsing (PEM/DER)
- Certificate chain verification
- Foundation for TLS module (`std/tls`)
