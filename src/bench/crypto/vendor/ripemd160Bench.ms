import { digestSync } from "../../../test/crypto/oracle";
import { ripemd160Of } from "std/crypto/pure/ripemd160";

const ROUNDS = 7;
let sink: number = 0;

function nsPerByte(size: int32, op: () => void): number {
	const calls = Math.max(1, Math.floor(16777216 / size));
	const start = performance.now();
	for (let i = 0; i < calls; i++) op();
	return (performance.now() - start) * 1000000 / (calls * size);
}

function median(values: number[]): number {
	const sorted = values.slice(0).sort((a, b) => a - b);
	return sorted[sorted.length >> 1];
}

for (const size of [64, 1024, 65536]) {
	const data = new Array<uint8>(size);
	for (let i = 0; i < size; i++) data[i] = ((i * 31 + 7) & 255) as uint8;
	const pure: number[] = [];
	const vendor: number[] = [];
	for (let r = 0; r < ROUNDS; r++) {
		pure.push(nsPerByte(size, () => { sink += ripemd160Of(data).length; }));
		vendor.push(nsPerByte(size, () => {
			const result = digestSync("ripemd160", data);
			if (result.ok) sink += result.value.length;
		}));
	}
	const p = median(pure);
	const v = median(vendor);
	console.log(`${size} B: pure ${p.toFixed(2)} ns/B, vendor ${v.toFixed(2)} ns/B, pure/vendor ${(p / v).toFixed(2)}`);
}
console.log(`sink ${sink}`);
