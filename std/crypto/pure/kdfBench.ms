import { hmacSync, pbkdf2Sync } from "std/crypto/oracle";
import { hmacOf, pbkdf2Of } from "./hmac";
import { kindSha256 } from "./state";

let sink: number = 0;

function msPerCall(op: () => void): number {
	let calls = 1;
	while (true) {
		const start = performance.now();
		for (let i = 0; i < calls; i++) op();
		const elapsed = performance.now() - start;
		if (elapsed >= 100.0) return elapsed / calls;
		calls = calls * 4;
	}
}

function median(values: number[]): number {
	const sorted = values.slice(0).sort((a, b) => a - b);
	return sorted[sorted.length >> 1];
}

function bytesOf(count: int32): uint8[] {
	const out = new Array<uint8>(count);
	for (let i = 0; i < count; i++) out[i] = ((i * 31 + 7) & 255) as uint8;
	return out;
}

const key = bytesOf(32);
for (const size of [64, 1024, 65536]) {
	const data = bytesOf(size);
	const pure: number[] = [];
	const vendor: number[] = [];
	for (let r = 0; r < 5; r++) {
		pure.push(msPerCall(() => { sink += hmacOf(kindSha256, key, data)[0]; }) * 1000000.0 / size);
		vendor.push(msPerCall(() => {
			const result = hmacSync("sha256", key, data);
			if (result.ok) sink += result.value.length;
		}) * 1000000.0 / size);
	}
	const p = median(pure);
	const v = median(vendor);
	console.log(`hmac-sha256 ${size} B: pure ${p.toFixed(2)} ns/B, vendor ${v.toFixed(2)} ns/B, pure/vendor ${(p / v).toFixed(2)}`);
}

const password = bytesOf(16);
const salt = bytesOf(16);
const iterations = 10000;
const pure: number[] = [];
const vendor: number[] = [];
for (let r = 0; r < 5; r++) {
	pure.push(iterations * 1000.0 / msPerCall(() => { sink += pbkdf2Of(kindSha256, password, salt, iterations, 32)[0]; }));
	vendor.push(iterations * 1000.0 / msPerCall(() => {
		const result = pbkdf2Sync(password, salt, iterations, 32, "sha256");
		if (result.ok) sink += result.value.length;
	}));
}
const p = median(pure);
const v = median(vendor);
console.log(`pbkdf2-sha256 32 B: pure ${p.toFixed(0)} it/s, vendor ${v.toFixed(0)} it/s, vendor/pure ${(v / p).toFixed(2)}`);
console.log(`sink ${sink}`);
