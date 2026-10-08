// @exit: 1
// @stdout: before string s
// @xfail(raiser): the Raiser stops at the same conversion with exit 1, but prints its 'raiser runtime error: member …' line in its own format, which parity compares with C's merged output
// note: `as` to a union that shares some members, on a value holding a member the target lacks, stops with the member-check error instead of reading the wrong slot (sibling: unionAsOverlappingUnion).
function show(u: string | boolean): string {
	if (typeof u === "string") return "string " + u;
	return u ? "boolean true" : "boolean false";
}
function src(c: int32): int32 | string | boolean {
	if (c == 0) return "s";
	return 9;
}
console.log("before " + show(src(0) as string | boolean));
console.log("after " + show(src(1) as string | boolean));
