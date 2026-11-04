# std/crypto — design

One crypto API on every backend: the same call gives the same bytes on C and on JS. This file owns the decisions behind the public surface, where each backend's implementation comes from, what was measured against Node, and how the cross-implementation test constants were made. The surface itself is the code: `std/crypto/index.cms` and `index.jms` (hash, HMAC, KDF, random, encoding), one folder per algorithm family (`aes`, `chacha20`, `blake2b`, `argon2`, `ed25519`, `x25519`, `rsa`, `ec`, `tls`), errors in `std/crypto/errors.ms`.

## 1. The contract

Decided by the person on 2026-11-01 ("async-first on every backend", `*Sync` kept, WebCrypto on JS with portable `.ms` for what it lacks); the last three rules were recommended in the same brief and accepted ("tiếp nha").

- **An operation without a suffix is async** and returns `Promise<Result<T, CryptoError>>`. WebCrypto is async-only, so an async default is the only shape that is the same call on both backends. On C the async form calls the Sync form inside the async function without spawning; measured on 2026-11-01 at 305 ns against 250-345 ns for the Sync call (tree not recorded), so the async default costs a native caller nothing.
- **Every async operation has a `*Sync` twin** ("để ai cần thì vẫn có thể dùng bản sync", confirmed for all of them). Code on a `spawn` worker uses the Sync forms, because a thunk returning a promise cannot be spawned. On JS every Sync form runs the portable code in `std/crypto/pure/`, since WebCrypto has no sync API; random is the exception (`crypto.getRandomValues` is sync).
- **Encoding is sync under its plain name** (`toHex`, `fromHex`, `toBase64`, `fromBase64`, `timingSafeEqual`): nothing in it waits, so it has no async form.
- **Results are `Buffer`; there is no `encoding` parameter.** Callers format with `toHex`/`toBase64`. A malformed `fromHex`/`fromBase64` input is a `Result.err`, never an empty or partial buffer.
- **Inputs are `Bytes`, and a string means its UTF-8 bytes** on every backend, as Node's `update(string)` does.
- **Errors are `Result<T, CryptoError>`; nothing throws** except a call on a destroyed key, which is a programming error and throws `Error`. The JS tier maps WebCrypto rejections onto `CryptoErrorKind`.
- **Keys are opaque classes** carrying their algorithm, so a key of the wrong algorithm is a compile-time type error. `onDestroy` frees and wipes the native state on C and drops the `CryptoKey` on JS. Raw, PEM and seed bytes leave a key only through an explicit import/export call. An Ed25519 private key holds its public key, so signing does not derive it again (deriving it per sign cost 2x).

Out of the contract, on purpose: non-blocking TLS on the io engine (`TlsConnection` keeps blocking reads and writes), argon2 secret and associated-data inputs (added when a consumer asks).

## 2. Where each backend's code comes from

| family | C (`index.cms`) | JS async (`index.jms`) | JS Sync and fallback |
|---|---|---|---|
| sha1/2, md5, HMAC, PBKDF2, HKDF | mbedTLS md, SHA-256 rounds in `runtime/crypto/sha256Hw.c` (Armv8 SHA, x86 SHA-NI by cpuid), SHA-512 on A64 SHA-512 instructions where present | `subtle.digest`, `HMAC`, `PBKDF2`, `HKDF`; md5, sha224 and streaming hashers portable | `pure/sha2.ms`, `sha1.ms`, `md5.ms`, `hmac.ms` |
| AES-GCM, AES-CBC | `runtime/crypto/ciphers/aesGcmHw.c` (Arm AES+PMULL, AES-NI+PCLMUL) over the vendor GCM | `AES-GCM`, `AES-CBC` | `pure/aes.ms`, `ghash.ms` |
| XChaCha20-Poly1305 | `runtime/crypto/ciphers/chacha20*.c`, `poly1305*.c`; Monocypher 4.0.2 as tail and byte oracle | portable | `pure/chacha.ms`, `poly1305.ms` |
| blake2b, argon2 | Monocypher, vendor argon2 | portable | `pure/blake2b.ms`, `argon2.ms` |
| Ed25519, X25519 | Monocypher (`runtime/crypto/curves/`) | `Ed25519`, `X25519` where `subtle` has them | `pure/ed25519.ms`, `x25519.ms`, `field25519.ms`; also when `subtle` is missing (a browser outside a secure context) |
| RSA, ECDSA/ECDH P-256/384 | mbedTLS PSA | `RSASSA-PKCS1-v1_5`, `RSA-PSS`, `RSA-OAEP`, `ECDSA`, `ECDH` | `pure/rsa.ms`, `p256.ms`, `p384.ms` on native `BigInt` |
| TLS | mbedTLS | none | none |

The `.ms` rewrite of every C path is arc `std-crypto-ms`; until its default switch the C column stays as above.

## 3. C against Node

Numbers: `src/bench/crypto/baseline.md` (m1m and rtx, commands and trees there). The C tier leads or ties Node on every row except these, and the person closed the C-vs-Node work on 2026-11-03 with them open:

- **Ed25519 sign/verify and X25519** (1.1-2.2x behind on both hosts): Monocypher's field is ten 25.5-bit limbs with 32x32-bit products; OpenSSL uses 51-bit limbs with 64x64→128 products (and assembly on x86-64). The fix is a 64-bit-limb field, which arc `std-crypto-ms` carries in its `.ms` Ed25519.
- **SHA-512 at 1 MB on x86-64** (rtx 741 vs 1564 MB/s; m1m ties): mbedTLS has no x86 SHA-512 kernel, and Zen 5 has no SHA-512 instructions; OpenSSL runs an AVX2/BMI2 kernel. On aarch64 the A64 SHA-512 instructions close the gap.
- **SHA-256 at 1 MB** within 3-5%: noise-level on loaded hosts.

## 4. Constants made by other implementations

The interop pins hold keys, signatures and ciphertexts made outside this repo, so a regression that keeps C and JS agreeing with each other but not with the world still fails:

- `src/test/corpus/programs/cryptoJsRsaInterop.ms` and `cryptoJsRsaSync.ms`: RSA-2048 and P-256/P-384 material from one C run (mbedTLS), one JS run on those keys (WebCrypto) and one Node run. The Node half is regenerated with this script (node 24, `node gen.js`), whose `name=value` lines become the `node*` constants:

```js
const crypto = require("node:crypto");
function line(name, text) { console.log(name + "=" + JSON.stringify(text)); }
const rsa = crypto.generateKeyPairSync("rsa", { modulusLength: 2048, privateKeyEncoding: { type: "pkcs8", format: "pem" }, publicKeyEncoding: { type: "spki", format: "pem" } });
line("nodeRsaPkcs8Pem", rsa.privateKey);
line("nodeRsaPublicPem", rsa.publicKey);
line("nodeRsaSig", crypto.sign("sha256", Buffer.from("abc"), rsa.privateKey).toString("hex"));
line("nodeRsaPssSig", crypto.sign("sha256", Buffer.from("abc"), { key: rsa.privateKey, padding: crypto.constants.RSA_PKCS1_PSS_PADDING, saltLength: 32 }).toString("hex"));
line("nodeRsaOaep", crypto.publicEncrypt({ key: rsa.publicKey, padding: crypto.constants.RSA_PKCS1_OAEP_PADDING, oaepHash: "sha256" }, Buffer.from("oaep from node")).toString("hex"));
for (const [name, curve, hash] of [["p256", "prime256v1", "sha256"], ["p384", "secp384r1", "sha384"]]) {
	const a = crypto.generateKeyPairSync("ec", { namedCurve: curve, privateKeyEncoding: { type: "pkcs8", format: "pem" }, publicKeyEncoding: { type: "spki", format: "pem" } });
	const b = crypto.generateKeyPairSync("ec", { namedCurve: curve });
	line("node" + name + "Pkcs8Pem", a.privateKey);
	line("node" + name + "PublicPem", a.publicKey);
	line("node" + name + "Sig", crypto.sign(hash, Buffer.from("abc"), a.privateKey).toString("hex"));
	line("node" + name + "PeerPublicPem", b.publicKey.export({ type: "spki", format: "pem" }));
	line("node" + name + "Shared", crypto.diffieHellman({ privateKey: crypto.createPrivateKey(a.privateKey), publicKey: b.publicKey }).toString("hex"));
	line("node" + name + "PeerPkcs8Pem", b.privateKey.export({ type: "pkcs8", format: "pem" }));
}
```

  The C and JS halves come from running the pin's own sign/encrypt calls on each backend and printing the hex; PKCS#1 v1.5 signing is deterministic, so their constants must reproduce exactly, while PSS, OAEP and ECDSA are randomized and are checked by verifying, not by equality.
- `src/test/corpus/programs/chachaBlockBoundaries.ms`: blobs sealed by Monocypher `crypto_aead_lock` (key, nonce and pattern scheme in its header). A rebuilt generator must reproduce every existing entry byte for byte before it adds one.
- `src/test/crypto/aeadOracle.c`: AEAD seal and open held to the vendored libraries at test time.
