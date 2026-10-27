// @stdout: local 13
// @stdout: returned 6
// @stdout: tuple 3
// @stdout: field 7 9
// @stdout: wide 2 true
// note: a sized array or a tuple of plain words is a value that leaves nothing behind once its owner is gone: a local, a returned value, a field of a struct and of a class, and a BitSet wider than one word
enum Wide { F0, F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12, F13, F14, F15, F16, F17, F18, F19, F20, F21, F22, F23, F24, F25, F26, F27, F28, F29, F30, F31, F32, F33, F34, F35, F36, F37, F38, F39, F40, F41, F42, F43, F44, F45, F46, F47, F48, F49, F50, F51, F52, F53, F54, F55, F56, F57, F58, F59, F60, F61, F62, F63, F64 }
type Pair = [int32, int32];
struct Box4 { q: int32[4]; tag: int32; }
class Holder { q: int32[4] = [0, 0, 0, 0]; pair: Pair = [0, 0]; }

function local(): int32 {
	let a: int32[4] = [1, 2, 3, 4];
	a[1] = 9;
	return a[1] + a[3];
}

function make(): int32[4] { return [1, 2, 3, 4]; }

function returned(): int32 {
	const a = make();
	const b = make();
	return a[1] + b[3];
}

function tuple(): int32 {
	let p: Pair = [1, 2];
	return p[0] + p[1];
}

function field(): string {
	let b: Box4 = { q: [5, 6, 7, 8], tag: 1 };
	const h = new Holder();
	h.q = [0, 0, 9, 0];
	h.pair = [3, 4];
	return `${b.q[2]} ${h.q[2]}`;
}

function wide(): string {
	const a = (0 as BitSet<Wide>).incl(Wide.F0).incl(Wide.F64);
	const b = a;
	return `${b.toItems().length} ${a.has(Wide.F64)}`;
}

for (let r = 0; r < 3; r++) {
	const l = local();
	const t = returned();
	const p = tuple();
	const f = field();
	const w = wide();
	if (r == 2) {
		console.log(`local ${l}`);
		console.log(`returned ${t}`);
		console.log(`tuple ${p}`);
		console.log(`field ${f}`);
		console.log(`wide ${w}`);
	}
}
