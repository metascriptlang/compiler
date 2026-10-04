// @xfail(c): card 2026-10-03-selfhost-noop-perturbation-flips-checker — the
// @xfail(orc): `copy = new Array(0)` reassignment loses the field-path root's
// @xfail(danger): resolvedSym in alias analysis under a cold cache; the two
// valueStorageParked tests hold the same contract.
// @stdout: byte 8 8 true false 0 1 true | word 8 8 true false 0 1 true | aggregate65 3 3 true false 0 1 true | aggregate100 3 3 true false 0 1 true
// @exit: 0
enum ByteFlag { Changed, Paint }
enum WordFlag { Changed, Paint, C, D, E, F, G, H, High }
interface ByteOwner { bits: Vec<BitSet<ByteFlag>>; }
interface WordOwner { bits: Vec<BitSet<WordFlag>>; }
enum Aggregate65Flag {
	F0, F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12, F13, F14, F15,
	F16, F17, F18, F19, F20, F21, F22, F23, F24, F25, F26, F27, F28, F29, F30, F31,
	F32, F33, F34, F35, F36, F37, F38, F39, F40, F41, F42, F43, F44, F45, F46, F47,
	F48, F49, F50, F51, F52, F53, F54, F55, F56, F57, F58, F59, F60, F61, F62, F63,
	F64,
}
enum Aggregate100Flag {
	F0, F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12, F13, F14, F15,
	F16, F17, F18, F19, F20, F21, F22, F23, F24, F25, F26, F27, F28, F29, F30, F31,
	F32, F33, F34, F35, F36, F37, F38, F39, F40, F41, F42, F43, F44, F45, F46, F47,
	F48, F49, F50, F51, F52, F53, F54, F55, F56, F57, F58, F59, F60, F61, F62, F63,
	F64, F65, F66, F67, F68, F69, F70, F71, F72, F73, F74, F75, F76, F77, F78, F79,
	F80, F81, F82, F83, F84, F85, F86, F87, F88, F89, F90, F91, F92, F93, F94, F95,
	F96, F97, F98, F99,
}
interface Aggregate65Owner { bits: Vec<BitSet<Aggregate65Flag>>; }
interface Aggregate100Owner { bits: Vec<BitSet<Aggregate100Flag>>; }

function byteLifecycle(): string {
	const owner: ByteOwner = { bits: [] };
	const changed = (0 as BitSet<ByteFlag>).incl(ByteFlag.Changed);
	for (let i: int32 = 0; i < 8; i++) { owner.bits.push(changed); }
	let copy: Vec<BitSet<ByteFlag>> = owner.bits;
	const before = owner.bits.length;
	const copied = copy.length;
	copy[0] = (0 as BitSet<ByteFlag>).incl(ByteFlag.Paint);
	const kept = owner.bits[0].has(ByteFlag.Changed);
	const shared = owner.bits[0].has(ByteFlag.Paint);
	owner.bits = new Array(0);
	const empty = owner.bits.length;
	copy = new Array(0);
	owner.bits.push((0 as BitSet<ByteFlag>).incl(ByteFlag.Paint));
	return `byte ${before} ${copied} ${kept} ${shared} ${empty} ${owner.bits.length} ${owner.bits[0].has(ByteFlag.Paint)}`;
}

function wordLifecycle(): string {
	const owner: WordOwner = { bits: [] };
	const changed = (0 as BitSet<WordFlag>).incl(WordFlag.Changed);
	for (let i: int32 = 0; i < 8; i++) { owner.bits.push(changed); }
	let copy: Vec<BitSet<WordFlag>> = owner.bits;
	const before = owner.bits.length;
	const copied = copy.length;
	copy[0] = (0 as BitSet<WordFlag>).incl(WordFlag.High);
	const kept = owner.bits[0].has(WordFlag.Changed);
	const shared = owner.bits[0].has(WordFlag.High);
	owner.bits = new Array(0);
	const empty = owner.bits.length;
	copy = new Array(0);
	owner.bits.push((0 as BitSet<WordFlag>).incl(WordFlag.High));
	return `word ${before} ${copied} ${kept} ${shared} ${empty} ${owner.bits.length} ${owner.bits[0].has(WordFlag.High)}`;
}

function aggregate65Lifecycle(): string {
	const owner: Aggregate65Owner = { bits: [] };
	const value = (0 as BitSet<Aggregate65Flag>).incl(Aggregate65Flag.F0).incl(Aggregate65Flag.F64);
	for (let i: int32 = 0; i < 3; i++) { owner.bits.push(value); }
	let copy: Vec<BitSet<Aggregate65Flag>> = owner.bits;
	const before = owner.bits.length;
	const copied = copy.length;
	copy[0] = (0 as BitSet<Aggregate65Flag>).incl(Aggregate65Flag.F64);
	const kept = owner.bits[0].has(Aggregate65Flag.F0);
	const shared = copy[0].has(Aggregate65Flag.F0);
	owner.bits = new Array(0);
	const empty = owner.bits.length;
	copy = new Array(0);
	owner.bits.push(value);
	return `aggregate65 ${before} ${copied} ${kept} ${shared} ${empty} ${owner.bits.length} ${owner.bits[0].has(Aggregate65Flag.F64)}`;
}

function aggregate100Lifecycle(): string {
	const owner: Aggregate100Owner = { bits: [] };
	const value = (0 as BitSet<Aggregate100Flag>).incl(Aggregate100Flag.F0).incl(Aggregate100Flag.F99);
	for (let i: int32 = 0; i < 3; i++) { owner.bits.push(value); }
	let copy: Vec<BitSet<Aggregate100Flag>> = owner.bits;
	const before = owner.bits.length;
	const copied = copy.length;
	copy[0] = (0 as BitSet<Aggregate100Flag>).incl(Aggregate100Flag.F99);
	const kept = owner.bits[0].has(Aggregate100Flag.F0);
	const shared = copy[0].has(Aggregate100Flag.F0);
	owner.bits = new Array(0);
	const empty = owner.bits.length;
	copy = new Array(0);
	owner.bits.push(value);
	return `aggregate100 ${before} ${copied} ${kept} ${shared} ${empty} ${owner.bits.length} ${owner.bits[0].has(Aggregate100Flag.F99)}`;
}

console.log(`${byteLifecycle()} | ${wordLifecycle()} | ${aggregate65Lifecycle()} | ${aggregate100Lifecycle()}`);
