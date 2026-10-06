// GUARD-OS solana
// A struct call assigned to a frame local writes that local, and a struct call result passed by
// address is read where the call left it. Each temporary the call used to go through took its own
// SBF stack slot: `score` measured 5,184 bytes before, 2,624 after (platform-tools v1.57, -O2).
// RED MEANS: a call result went back through a temporary and `score` overflows the 4,096-byte SBF frame.
import { instructionData, logU64 } from "std/solana";
import { Pet, gain, weigh } from "./fixtures/solanaFrameStructs";

function score(a: Pet, b: Pet, n: uint64): uint64 {
	const w = weigh(gain(a, 1)) + weigh(gain(b, 2)) + weigh(gain(a, 3));
	const hit = n % 2 == 0 ? gain(a, n) : b;
	const miss = n % 3 == 0 ? gain(b, n) : a;
	let last = a;
	if (n > 5) { last = gain(hit, 4); }
	return w + weigh(hit) + weigh(miss) + weigh(last);
}

function main(): void {
	const n = instructionData().length as uint64;
	const p: Pet = { burrow: 100 + n, harvest: 50, xp: 0, slot: 1, a0: 0, a1: 0, a2: 0, a3: 0, a4: 0, a5: 0, a6: 0, a7: 0, b0: 0, b1: 0, b2: 0, b3: 0, b4: 0, b5: 0, b6: 0, b7: 0, c0: 0, c1: 0, c2: 0, c3: 0, c4: 0, c5: 0, c6: 0, c7: 0, d0: 0, d1: 0, d2: 0, d3: 0, d4: 0, d5: 0, d6: 0, d7: 0, e0: 0, e1: 0, e2: 0, e3: 0, e4: 0, e5: 0, e6: 0, e7: 0, f0: 0, f1: 0, f2: 0, f3: 0, f4: 0, f5: 0, f6: 0, f7: 0, hearts: 3, alive: true };
	const q: Pet = { ...p, slot: 2 };
	logU64(score(p, q, n));
}
main();
