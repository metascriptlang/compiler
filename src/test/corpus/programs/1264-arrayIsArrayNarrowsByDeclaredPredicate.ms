// @stdout: 3 -1 3 102 7 -1 2 false false true false
type In = string | Buffer | uint8[];
class Pt { x: int32 = 7; }
function size(view: Readonly<Span<uint8>>): int32 { return view.length as int32; }
function bytes(data: In): int32 {
	if (Array.isArray(data)) return size(data);
	return -1;
}
function words(d: string | int32[]): int32 {
	if (Array.isArray(d)) return d.length;
	return d.length + 100;
}
function pointOrList(d: Pt | int32[]): int32 {
	if (Array.isArray(d)) return -1;
	return d.x;
}
function maybe(d: int32[] | null): int32 {
	if (Array.isArray(d)) return d.length;
	return -1;
}
function plain(d: int32[]): int32 {
	if (Array.isArray(d)) { const e: int32[] = d; return e.length; }
	return 0;
}
function listed(v: string | int32[] | null): boolean { return Array.isArray(v); }
function opaque(v: unknown): boolean { return Array.isArray(v); }
console.log(`${bytes([1, 2, 3])} ${bytes("x")} ${words([1, 2, 3])} ${words("ab")} ${pointOrList(new Pt())} ${pointOrList([1])} ${plain([1, 2]) + maybe(null) + 1} ${listed(null)} ${listed("s")} ${listed([1])} ${opaque(new Pt())}`);
