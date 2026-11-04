import { Buffer } from "std/core/buffer";
import { ChaChaKey, sealSync, openSync } from "../chacha20";
import { keyWords, xchachaSealInto, xchachaOpenInto } from "./chacha";

class Rng {
	state: uint32;
}

function nextWord(rng: Rng): uint32 {
	let x = rng.state;
	x = x ^ (x << 13);
	x = x ^ (x >> 17);
	x = x ^ (x << 5);
	rng.state = x;
	return x;
}

function randomBuffer(rng: Rng, size: int32): Buffer {
	const out = Buffer.alloc(size);
	for (let i = 0; i < size; i++) out[i] = (nextWord(rng) & 255) as uint8;
	return out;
}

function sameBytes(a: Readonly<uint8[]>, b: Readonly<uint8[]>): boolean {
	if (a.length != b.length) return false;
	for (let i = 0; i < a.length; i++) if (a[i] != b[i]) return false;
	return true;
}

function differentialSizes(): int32[] {
	const sizes: int32[] = [];
	for (let i = 0; i <= 300; i++) sizes.push(i);
	for (const edge of [383, 384, 385, 511, 512, 513, 1023, 1024, 1025, 2047, 2048]) sizes.push(edge);
	return sizes;
}

/** Vendor and pure agree on the sealed bytes for one nonce, open each other's output, and both refuse one flipped byte. */
function agreeOnce(rng: Rng, size: int32): boolean {
	const raw = randomBuffer(rng, 32);
	const vendorKey = ChaChaKey.import(raw);
	if (!vendorKey.ok) return false;
	const kw = new Array<uint32>(8);
	if (!keyWords(raw, kw)) return false;
	const plain = randomBuffer(rng, size);
	const aad = randomBuffer(rng, (nextWord(rng) % 70) as int32);

	const vendorSealed = sealSync(vendorKey.value, plain, aad);
	if (!vendorSealed.ok) return false;
	const pureSealed = new Array<uint8>(size + 40);
	for (let i = 0; i < 24; i++) pureSealed[i] = vendorSealed.value[i];
	if (!xchachaSealInto(kw, aad, plain, pureSealed)) return false;
	if (!sameBytes(pureSealed, vendorSealed.value)) return false;

	const pureOpened = new Array<uint8>(size);
	if (!xchachaOpenInto(kw, aad, vendorSealed.value, pureOpened) || !sameBytes(pureOpened, plain)) return false;
	const vendorOpened = openSync(vendorKey.value, pureSealed, aad);
	if (!vendorOpened.ok || !sameBytes(vendorOpened.value, plain)) return false;

	const forged = Buffer.copy(vendorSealed.value);
	const at = (nextWord(rng) % (forged.length as uint32)) as int32;
	forged[at] = forged[at] ^ ((1 << (nextWord(rng) % 8)) as uint8);
	const pureForged = new Array<uint8>(size);
	return !xchachaOpenInto(kw, aad, forged, pureForged) && !openSync(vendorKey.value, forged, aad).ok;
}

test "pure xchacha20poly1305 matches the native surface byte for byte over seeded inputs" {
	const rng: Rng = { state: 0x9e3779b9 };
	let cases = 0;
	for (let round = 0; round < 2; round++) {
		for (const size of differentialSizes()) {
			const agreed = agreeOnce(rng, size);
			if (!agreed) console.log(`differential mismatch at size ${size}, round ${round}`);
			assert agreed;
			cases += 1;
		}
	}
	console.log(`differential: ${cases} cases agreed`);
}
