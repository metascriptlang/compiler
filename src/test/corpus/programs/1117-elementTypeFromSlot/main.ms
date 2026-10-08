// @stdout: 2 3 5|0 2
// note: an array literal led by a spread takes its element type from the Span it fills, and the
// dead `?? []` arm of a left side already narrowed non-null takes the left's type. Both used to
// leave the element type unresolved and stop codegen with "unresolved type (kind=48)".
function take(items: Span<int32>): int32 { return items.length as int32; }
function sum(bytes: Readonly<Span<uint8>>): int32 { let t = 0; for (const b of bytes) t += b; return t; }
const v: Vec<int32> = [1, 2];
const out: string[] = [];
out.push(`${take([...v])} ${take([...v, 9])} ${sum([..."ab\u0003".asBytes()]) - 195 + 2}`);
function g(f: string[] | null): number {
	f = [];
	const w = f ?? [];
	return w.length;
}
function h(f: int32[] | null): number {
	f = [4, 5];
	return (f ?? []).length;
}
out.push(`${g(null)} ${h(null)}`);
console.log(out.join("|"));
