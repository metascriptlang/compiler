import { argv } from "std/process";

function churn(rounds: int32): number {
	const b = Buffer.alloc(4096);
	let sum: number = 0;
	for (let r: int32 = 0; r < rounds; r++) {
		for (let i: int32 = 0; i < 4096; i += 4) { b.writeUInt32LE(r + i, i); }
		for (let i: int32 = 0; i < 4096; i += 4) { sum += b.readUInt32LE(i); }
		sum += b[r % 4096];
	}
	return sum;
}

const rounds: int32 = argv.length > 1 ? argv[1].parseInt() as int32 : 2000;
console.log(`bufferBytes ${churn(rounds)}`);
