// @stdout: string s|boolean true|string t|Box 1|center,center
// note: `as` to a union that shares some members converts a value whose member the target holds, re-tagged into the target's slot; a string member converts into a set of string literals the held text belongs to. A value holding a member the target lacks stops the program (sibling: unionAsOverlappingUnionStops). Same output on C, JS and the Raiser.
class Box {
	n: int32;
	constructor(n: int32) { this.n = n; }
}
function show(u: string | boolean): string {
	if (typeof u === "string") return "string " + u;
	return u ? "boolean true" : "boolean false";
}
function showBox(u: Box | string | int32): string {
	if (u instanceof Box) return "Box " + u.n;
	if (typeof u === "string") return "string " + u;
	return "int32";
}
function src(c: int32): int32 | string | boolean {
	if (c == 0) return "s";
	if (c == 1) return true;
	return 9;
}
function mixed(c: int32): boolean | string | Box {
	if (c == 0) return "t";
	return new Box(1);
}
type Align = "auto" | "center";
function wire(c: int32): int32 | string {
	return c == 0 ? "center" : 3;
}
function showAlign(a: Align | null): string {
	return a == null ? "null" : a;
}
const out: string[] = [];
for (let c = 0; c < 2; c++) out.push(show(src(c) as string | boolean));
for (let c = 0; c < 2; c++) out.push(showBox(mixed(c) as string | Box | int32));
out.push(showAlign(wire(0) as Align | null) + "," + showAlign(wire(0) as Align));
console.log(out.join("|"));
