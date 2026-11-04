// Pure XChaCha20-Poly1305 seal against the native surface, interleaved, median
// ns/byte per size.
//   msc build std/crypto/pure/chachaBench.ms --danger --output=out/bench &&
// out/bench

import { Buffer } from "std/core/buffer";
import { ChaChaKey, sealSync } from "../chacha20";
import { keyWords, xchachaSealInto } from "./chacha";

const MIN_ROUND_MS = 60.0;
const ROUNDS = 5;
let sink: int32 = 0;

function nsPerByte(op: () => void, size: int32): number {
	let calls = 1;
	while (true) {
		const start = performance.now();
		for (let i = 0; i < calls; i++) op();
		const elapsed = performance.now() - start;
		if (elapsed >= MIN_ROUND_MS) return (elapsed * 1000000.0) / calls / size;
		calls = calls * 4;
	}
}

function median(xs: number[]): number {
	xs.sort((a, b) => a - b);
	return xs[xs.length >> 1];
}

const raw = Buffer.alloc(32);
for (let i = 0; i < 32; i++) raw[i] = (i * 3 + 1) as uint8;
const imported = ChaChaKey.import(raw);
if (!imported.ok) throw new Error("bench key refused");
const vendorKey = imported.value;
const words = new Array<uint32>(8);
keyWords(raw, words);
const aad = Buffer.alloc(13);

for (const size of [64, 1024, 65536]) {
	const data = Buffer.alloc(size);
	for (let i = 0; i < size; i++) data[i] = ((i * 31 + 7) & 255) as uint8;
	const pure: number[] = [];
	const vendor: number[] = [];
	for (let r = 0; r < ROUNDS; r++) {
		pure.push(
			nsPerByte(() => {
				const out = new Array<uint8>(size + 40);
				xchachaSealInto(words, aad, data, out);
				sink += out[size + 39];
			}, size),
		);
		vendor.push(
			nsPerByte(() => {
				const v = sealSync(vendorKey, data, aad);
				if (v.ok) sink += v.value[size + 39];
			}, size),
		);
	}
	const p = median(pure);
	const v = median(vendor);
	console.log(
		`${size} B  pure ${p.toFixed(2)} ns/B  vendor ${v.toFixed(2)} ns/B  pure/vendor ${(p / v).toFixed(2)}`,
	);
}
console.log(`sink ${sink}`);
