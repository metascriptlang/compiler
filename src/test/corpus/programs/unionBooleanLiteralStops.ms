// @exit: 1
// @stdout: before true
// @xfail(raiser): the Raiser stops at the same conversion with exit 1, but prints its 'raiser runtime error: member …' line in its own format, which parity compares with C's merged output
// note: `as true | null` on a union holding boolean whose held value is false stops with the member-check error instead of reading the boolean as the literal (sibling: unionBooleanLiteral).
function flag(c: int32): boolean | string { return c == 0 ? true : false; }
function showT(t: true | null): string { return t == null ? "null" : "true"; }
console.log("before " + showT(flag(0) as true | null));
console.log("after " + showT(flag(1) as true | null));
