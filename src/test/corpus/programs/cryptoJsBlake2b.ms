// BLAKE2b gives the same bytes on the C backend (Monocypher) and on JS (the portable code in
// std/crypto/pure): the RFC 7693 "abc" vector and the empty input at 64 bytes, the BLAKE2 reference
// keyed vectors (key 00..3f, empty input and input 00..fe), a 300-byte pattern at sizes 1, 16, 32, 48
// and 64, a 16-byte key at size 20, and streaming in chunks that land on, before and after the 128-byte
// block edge equals the one-shot digest. The expected hex was computed independently of both backends.
//
// @stdout: empty512 786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce
// @stdout: abc512 ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923
// @stdout: key64 empty 10ebb67700b1868efb4417987acf4690ae9d972fb7a590c2f02871799aaa4786b5e996e8f0f4eb981fc214b005f42d2ff4233499391653df7aefcbc13fc51568
// @stdout: key64 in255 142709d62e28fcccd0af97fad0f8465b971e82201dc51070faa0372aa43e92484be1c1e73ba10906d5d1853db6a4106e0a7bf9800d373d6dee2d46d62ef2a461
// @stdout: pattern300 size 1 8a
// @stdout: pattern300 size 16 22a3d754c5897edb342424758cc1d017
// @stdout: pattern300 size 32 e0cbf7ecc22ef5a0c9570771adfd8b52bd9cdf303fa5a9f66a459ee20ad14564
// @stdout: pattern300 size 48 577f48d8fca0ec2a55eddd7efae66818748afeca0bb3dd4851ccc7ce4c07c7e8515d3b371468dc456da78ec6961c5cb2
// @stdout: pattern300 size 64 b7e35afe31bddc8abfb9c98783f9a3687812d175ce351ed3c75301cae551af1c5b31a0086d90290b566de24f1f55e3da2e71dfce432ac0261f29c213c682904e
// @stdout: keyed16 size20 112cff73ba19f818c72eebae909f82ef67531a06
// @stdout: streamed chunks 1 127 128 129 200 all equal true
// @exit: 0
// @skip-raiser: std/crypto has only a C backend (blake2b/index.cms over Monocypher); there is no blake2b.rms

import { Buffer } from "std/core/buffer";
import { CryptoError, toHex } from "std/crypto";
import { blake2b, blake2bKeyed, blake2bSync, createBlake2b } from "std/crypto/blake2b";

function must<T>(result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error(`crypto call failed: ${result.error.message}`);
	return result.value;
}

function counting(size: int32, mul: int32, add: int32): Buffer {
	const data = Buffer.alloc(size);
	for (let i = 0; i < size; i++) data[i] = ((i * mul + add) % 256) as uint8;
	return data;
}

const key64 = counting(64, 1, 0);
console.log(`empty512 ${toHex(must(await blake2b("", 64)))}`);
console.log(`abc512 ${toHex(must(await blake2b("abc", 64)))}`);
console.log(`key64 empty ${toHex(must(await blake2bKeyed(key64, "", 64)))}`);
console.log(`key64 in255 ${toHex(must(await blake2bKeyed(key64, counting(255, 1, 0), 64)))}`);

const pattern = counting(300, 7, 1);
for (const size of [1, 16, 32, 48, 64]) console.log(`pattern300 size ${size} ${toHex(must(await blake2b(pattern, size)))}`);
console.log(`keyed16 size20 ${toHex(must(await blake2bKeyed(counting(16, 1, 128), pattern, 20)))}`);

const whole = toHex(must(blake2bSync(pattern, 64)));
let allEqual = true;
for (const chunk of [1, 127, 128, 129, 200]) {
	const hasher = must(createBlake2b(64));
	for (let at = 0; at < pattern.length; at += chunk) hasher.update(pattern.slice(at, at + chunk));
	if (toHex(hasher.digest()) != whole) allEqual = false;
}
console.log(`streamed chunks 1 127 128 129 200 all equal ${allEqual}`);
