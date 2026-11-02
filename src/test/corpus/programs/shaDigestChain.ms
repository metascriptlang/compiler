// SHA-256 gives the same bytes on every backend and every input path: the message of length n has bytes
// (i * 131 + n * 7 + 3) mod 256, for n = 0..300 (every padding and block-edge case twice over) and a 1 MB
// message; each goes through digestSync, sha256Sync and createHash fed in uneven chunks, and the three agree.
// The chain line is the SHA-256 of the 302 digests concatenated, computed with Python's hashlib; the C backend
// runs the mbedTLS hash and JS its own portable tier, so equal output on both is the differential check.
//
// @stdout: sha256 paths agree true
// @stdout: sha256 chain c2f2000796e62453fac753baa9f859f156ab499e02938743372446478884a071
// @exit: 0
// @skip-raiser: the raiser std/crypto carries only the string-encoded hash family; none of these Buffer APIs
import { Buffer } from "std/core/buffer";
import { CryptoError, createHash, digestSync, sha256Sync, toHex } from "std/crypto";

function must<T>(result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error(`crypto call failed: ${result.error.message}`);
	return result.value;
}

function message(size: int32, n: int32): Buffer {
	const data = Buffer.alloc(size);
	for (let i = 0; i < size; i++) data[i] = ((i * 131 + n * 7 + 3) % 256) as uint8;
	return data;
}

const lengths: int32[] = [];
for (let n = 0; n <= 300; n++) lengths.push(n);
lengths.push(1048576);

const all = Buffer.alloc(lengths.length * 32);
let agree = true;
for (let k = 0; k < lengths.length; k++) {
	const size = lengths[k];
	const data = message(size, size == 1048576 ? 1000 : size);
	const viaDigest = must(digestSync("sha256", data));
	const viaSha256 = must(sha256Sync(data));
	const chunk = size == 1048576 ? 4099 : 1 + (size % 70);
	const hasher = createHash("sha256");
	for (let at = 0; at < size; at += chunk) hasher.update(data.slice(at, at + chunk));
	const viaStream = hasher.digest();
	const hex = toHex(viaDigest);
	if (toHex(viaSha256) != hex || toHex(viaStream) != hex) agree = false;
	for (let i = 0; i < 32; i++) all[k * 32 + i] = viaDigest[i];
}
console.log(`sha256 paths agree ${agree}`);
console.log(`sha256 chain ${toHex(must(digestSync("sha256", all)))}`);
