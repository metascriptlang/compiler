// note: `as T`, `!` and `??` on value-carried `T | null` holding a value read it unchanged, from calls, fields, elements and narrowed locals.

struct P { x: int32 }

struct H { name: string | null; n: int32 | null }

function s(f: boolean): string | null { return f ? null : "abc"; }

function n(f: boolean): int32 | null { return f ? null : 4; }

function p(f: boolean): P | null {
	if (f) return null;
	const q: P = { x: 2 };
	return q;
}

const h: H = { name: "hn", n: 9 };
const xs: (int32 | null)[] = [1, null, 3];
let total = 0;
for (let i = 0; i < 3; i++) {
	if (xs[i] !== null) total += xs[i]!;
}
const m = s(false);
console.log(`${(s(false) as string).length} ${s(false)!} ${n(false)! + 1} ${(p(false) as P).x}`);
console.log(`${h.name!} ${(h.n as int32) * 2} ${total} ${s(true) ?? "dflt"} ${n(true) ?? 7}`);
if (m !== null) console.log(m!);
let acc = "";
for (let i = 0; i < 3; i++) {
	acc = acc + (s(false) as string);
}
console.log(acc);
