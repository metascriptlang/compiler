// @stdout: s:abc n:7 s:xy n:4 s:3 n:5
// note: `typeof` names the brand's base, so a union member that is a brand over a string or a number is
// kept or dropped by the same test as the plain primitive, in the then and in the else branch.
type Id = string & { __brand: "Id" };
type Num = number & { __brand: "Num" };
type ByNumber = number | Id;
type ByString = string | Num;

function viaNumber(d: ByNumber): string {
	if (typeof d == "string") return `s:${d}`;
	return `n:${d}`;
}
function viaString(d: ByString): string {
	if (typeof d != "string") return `n:${d}`;
	return `s:${d}`;
}
function elseBranch(d: ByNumber): string {
	if (typeof d == "number") return `n:${d + 1}`;
	return `s:${d.length}`;
}

const id = "abc" as Id;
const num = 4 as Num;
console.log(viaNumber(id), viaNumber(7), viaString("xy"), viaString(num), elseBranch(id), elseBranch(4));
