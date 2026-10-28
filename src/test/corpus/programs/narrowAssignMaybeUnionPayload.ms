// @stdout: 1 3 2 x15 7
// note: an assignment to a `T | null` local narrows it to the assigned member even when T is a union, and the slot keeps its Maybe storage, so the narrowed local still passes to a `ref` parameter of the declared type.

class Tag { a: int32 = 1; }
class Other { b: int32 = 2; }

function viaClass(hit: boolean): int32 {
	let u: Tag | Other | null = hit ? new Other() : null;
	if (u == null) { u = new Tag(); }
	return u instanceof Tag ? u.a : u.b;
}
function viaPrimitive(hit: boolean): string {
	let p: string | int32 | null = hit ? "ab" : null;
	if (p == null) { p = 3; }
	return typeof p == "string" ? p.length.toString() : p.toString();
}
function fill(ref x: Tag | null): int32 { return x == null ? -1 : x.a; }
function viaRef(): int32 {
	let held: Tag | null = null;
	held = new Tag();
	held.a = 7;
	return fill(held);
}
function viaStringRef(): string {
	let s: string | null = null;
	s = "x";
	return s + showRef(s);
}
function showRef(ref v: string | null): string { return v == null ? "none" : v.length.toString() + "5"; }

console.log(viaClass(false), viaPrimitive(false), viaClass(true), viaStringRef(), viaRef());
