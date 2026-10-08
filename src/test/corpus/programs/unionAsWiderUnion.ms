// @stdout: int32 4|string s|int32 4|string s|Box 2|string q|string a|int32 9
// note: `as` to a union holding more members, or the same members in another order, keeps the member the value holds; it is a conversion, not a reinterpretation of the narrower union's storage. Variants: a call result, a local, a class member and a nested union field. Same output on C, JS and the Raiser.
class Box {
	n: int32;
	constructor(n: int32) { this.n = n; }
}
struct Holder {
	u: int32 | string;
}
function show(u: boolean | int32 | string): string {
	if (typeof u === "string") return "string " + u;
	if (typeof u === "boolean") return "boolean";
	return "int32 " + u;
}
function showBox(u: boolean | string | Box): string {
	if (u instanceof Box) return "Box " + u.n;
	if (typeof u === "string") return "string " + u;
	return "boolean";
}
function narrow(c: int32): int32 | string {
	return c == 1 ? "s" : 4;
}
function box(c: int32): Box | string {
	return c == 0 ? new Box(2) : "q";
}
const out: string[] = [];
for (let c = 0; c < 2; c++) out.push(show(narrow(c) as boolean | int32 | string));
for (let c = 0; c < 2; c++) {
	const a = narrow(c);
	const w = a as string | boolean | int32;
	out.push(show(w));
}
for (let c = 0; c < 2; c++) out.push(showBox(box(c) as boolean | string | Box));
const holders: Holder[] = [{ u: "a" }, { u: 9 }];
for (const h of holders) out.push(show(h.u as boolean | int32 | string));
console.log(out.join("|"));
