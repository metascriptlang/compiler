// GUARD-OS solana
// Under --os=solana memcpy/memset/memcmp/memmove are the compiler builtins, so the SBF
// backend inlines small ones and calls the platform's syscall-backed symbols for large ones;
// a runtime byte loop in their place costs ~5 CU a byte (NIM-REF RT-22). RED MEANS the runtime
// shadows them.
import { instructionData, logU64 } from "std/solana";
@emit(`#if !defined(memcpy) || !defined(memset) || !defined(memcmp) || !defined(memmove)
#error mem* are not the compiler builtins under MSOS_SOLANA
#endif`);
struct Wide {
	a: uint64;
	b: uint64;
	c: uint64;
	d: uint64;
	e: uint64;
	f: uint64;
	g: uint64;
	h: uint64;
	i: uint64;
	j: uint64;
	k: uint64;
	l: uint64;
}
struct Big {
	bytes: uint8[1024];
	tag: uint64;
}
function wide(seed: uint64): Wide {
	return { a: seed, b: seed, c: seed, d: seed, e: seed, f: seed, g: seed, h: seed, i: seed,
		j: seed, k: seed, l: seed };
}
function big(seed: uint64): Big {
	let b: Big = { bytes: [], tag: seed };
	b.bytes[seed % 1024] = 3;
	return b;
}
function main(): void {
	const seed = instructionData().length;
	const x = big(seed);
	let y = x;
	y.bytes[(seed + 1) % 1024] = 5;
	logU64(wide(seed).l + y.tag + (x.bytes[seed % 1024] as uint64) + (x == y ? 1 : 0));
}
main();
