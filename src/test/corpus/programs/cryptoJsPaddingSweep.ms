// Every input length from 0 to 260 bytes across the padding and block boundaries of each hash gives the same digests
// on the C backend (mbedTLS) and on JS (the portable Sync code): the digests are folded through sha256 and compared
// with the value Node's crypto gives for the same inputs, and createHash fed in uneven chunks matches the one-shot digest.
//
// @stdout: sha1 3d461cb244eae7c1aaa7993c0833ac595441b6d075d5745ae0904515d4b5390d 0
// @stdout: sha224 cc57e6e1d0b33da62baf38a417774a6b8f9bf4e5df5f1ee6586f2aa34c349341 0
// @stdout: sha256 0cc209c6224061d707e13bec3a2030c118f26aa54893df4a7789e28ad756a7f0 0
// @stdout: sha384 13cb661004a94c8ff9393ffff5869c788bc9b5213c1713a3fe4ae0bfe8332d1b 0
// @stdout: sha512 bb214dbb22ab45aa57fa7b93a91100039259de7ce13849c9db6a05a0214203ae 0
// @stdout: md5 0b1a5816a35e05b54887b01a87d1064f0e6a511323daf39d83b8e701b4e331c6 0
// @exit: 0
// @skip-raiser: the raiser std/crypto carries only the string-encoded hash family; none of these Buffer APIs
import { Buffer } from "std/core/buffer";
import { HashAlgorithm, createHash, digestSync, toHex } from "std/crypto";

function patterned(length: int32): Buffer {
	const data = Buffer.alloc(length);
	for (let i = 0; i < length; i++) data[i] = ((i * 7 + length) & 255) as uint8;
	return data;
}

function sweep(algorithm: HashAlgorithm): void {
	const folded = createHash("sha256");
	let mismatches = 0;
	for (let length = 0; length <= 260; length++) {
		const data = patterned(length);
		const whole = digestSync(algorithm, data);
		if (!whole.ok) {
			mismatches++;
			continue;
		}
		folded.update(whole.value);
		const streamed = createHash(algorithm);
		const step = length % 13 + 1;
		for (let at = 0; at < length; at += step) {
			streamed.update(data.slice(at, at + step < length ? at + step : length));
		}
		if (toHex(streamed.digest()) != toHex(whole.value)) mismatches++;
	}
	console.log(algorithm, toHex(folded.digest()), mismatches);
}

const algorithms: HashAlgorithm[] = ["sha1", "sha224", "sha256", "sha384", "sha512", "md5"];
for (const algorithm of algorithms) sweep(algorithm);
