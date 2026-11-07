// @stdout: 8 4 5
import { Buffer } from "std/core/buffer";

function count(d: Readonly<Span<uint8>>): int32 {
	return d.length as int32;
}

async function run(): Promise<int32> {
	const x = Buffer.alloc(4);
	const n = count(x);
	await Promise.resolve(0);
	return n + count(x);
}

function direct(): int32 {
	const x = Buffer.alloc(4);
	return count(x);
}

function captured(): int32 {
	const x = Buffer.alloc(5);
	const read = (): int32 => count(x);
	return read();
}

console.log(await run(), direct(), captured());
