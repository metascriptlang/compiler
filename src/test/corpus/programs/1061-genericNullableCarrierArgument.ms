// Parity program — a generic `T | null` parameter taking an argument that is already the
// nullable carrier passes it unchanged; a bare value is wrapped once. Struct, tuple and
// primitive payloads, explicit and inferred `T`.
//
// @stdout: s:1|s:1|s:0|t:7|t:7|t:0|i:5|i:5|i:0|s:1
// @exit: 0

struct Cell { a: int32; s: string; }


function sFirst<T>(a: T | null, b: T | null): T | null { return a; }
function mkCell(): Cell | null { return { a: 1, s: "q" }; }
function mkTup(): [int32, string] | null { return [7, "t"]; }
function mkInt(): int32 | null { return 5; }
function noCell(): Cell | null { return null; }

function main(): void {
	const c = mkCell();
	const n = noCell();
	const r1 = sFirst<Cell>(c, c);
	const r2 = sFirst(mkCell(), mkCell());
	const r3 = sFirst(n, c);
	const t1 = sFirst(mkTup(), mkTup());
	const t2 = sFirst<[int32, string]>([7, "t"], mkTup());
	const t3 = sFirst<[int32, string]>(null, mkTup());
	const i1 = sFirst(mkInt(), mkInt());
	const i2 = sFirst<int32>(5, mkInt());
	const i3 = sFirst<int32>(null, 5);
	const r4 = sFirst<Cell>({ a: 1, s: "z" }, c);
	const out: string[] = [];
	out.push("s:" + (r1 != null ? String(r1.a) : "0"));
	out.push("s:" + (r2 != null ? String(r2.a) : "0"));
	out.push("s:" + (r3 != null ? String(r3.a) : "0"));
	out.push("t:" + (t1 != null ? String(t1[0]) : "0"));
	out.push("t:" + (t2 != null ? String(t2[0]) : "0"));
	out.push("t:" + (t3 != null ? String(t3[0]) : "0"));
	out.push("i:" + (i1 != null ? String(i1) : "0"));
	out.push("i:" + (i2 != null ? String(i2) : "0"));
	out.push("i:" + (i3 != null ? String(i3) : "0"));
	out.push("s:" + (r4 != null ? String(r4.a) : "0"));
	console.log(out.join("|"));
}
main();
