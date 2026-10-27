// Parity program: a callee wider than its caller writes words over the dead
// registers of the caller's caller; that frame's string temporaries must not
// read them back as references, through a direct call, a closure call and a
// Map with integer keys.
// @stdout: s0:2450 s1:2770 s2:3090
// @stdout: c0:2450 c1:2770 c2:3090
// @stdout: map 3 6 7 8

function wide(n: int64): int64 {
	const a0 = n * 16 + 6;
	const a1 = a0 + 16;
	const a2 = a1 + 16;
	const a3 = a2 + 16;
	const a4 = a3 + 16;
	const a5 = a4 + 16;
	const a6 = a5 + 16;
	const a7 = a6 + 16;
	const a8 = a7 + 16;
	const a9 = a8 + 16;
	const b0 = a9 + 16;
	const b1 = b0 + 16;
	const b2 = b1 + 16;
	const b3 = b2 + 16;
	const b4 = b3 + 16;
	const b5 = b4 + 16;
	const b6 = b5 + 16;
	const b7 = b6 + 16;
	const b8 = b7 + 16;
	const b9 = b8 + 16;
	return a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + b0 + b1 + b2 + b3 + b4 + b5 + b6 + b7 + b8 + b9 - 3000 + 2290;
}

function narrow(n: int64): int64 {
	return wide(n);
}

function label(prefix: string, i: int64): string {
	let s = prefix;
	const v = narrow(i);
	s = s + i.toString() + ":" + v.toString();
	return s;
}

function labelThrough(prefix: string, i: int64, f: (n: int64) => int64): string {
	let s = prefix;
	const v = f(i);
	s = s + i.toString() + ":" + v.toString();
	return s;
}

const direct: string[] = [];
const closed: string[] = [];
for (let i: int64 = 0; i < 3; i++) {
	direct.push(label("s", i));
	closed.push(labelThrough("c", i, (n: int64): int64 => narrow(n)));
}
console.log(direct.join(" "));
console.log(closed.join(" "));

const m = new Map<int64, int64>();
m.set(5, 6);
m.set(21, 7);
m.set(37, 8);
console.log("map", m.size, m.get(5) ?? 0, m.get(21) ?? 0, m.get(37) ?? 0);
