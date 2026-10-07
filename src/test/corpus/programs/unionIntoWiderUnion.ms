// @stdout: int32 0|string s|boolean true|int32 7|string n|boolean false|string n|Box 3|string t|Box 6|string f|int32 8|array 3|string x1|string x2|int32 5|null|string s|int32 5|boolean|string s/string s|int32 3/int32 3|string n|int32 7|string n,int32 7,boolean true
// note: a union value moves into a union holding more members by assignment, argument, return, object field, array element and field read, and keeps the member it holds: after branches that store a string or a boolean, from a narrower return, from a class member, from a subclass member into its base class, from a nested union field, from a nullable union, from a variable narrowed to fewer members and from a payload that owns memory. Same output on C, JS and the Raiser.
class Box {
	n: int32;
	constructor(n: int32) { this.n = n; }
}
class Crate extends Box {
	constructor(n: int32) { super(n); }
}
struct Holder {
	u: int32 | string;
}
function show(u: int32 | string | boolean): string {
	if (typeof u === "string") return "string " + u;
	if (typeof u === "boolean") return u ? "boolean true" : "boolean false";
	return "int32 " + u;
}
function stored(c: int32): int32 | string | boolean {
	let u: int32 | string | boolean = 0;
	if (c == 1) { u = "s"; } else if (c == 2) { u = true; }
	const keep = u;
	u = keep;
	return u;
}
function narrow(c: int32): int32 | string {
	return c == 1 ? "n" : 7;
}
function wide(c: int32): int32 | string | boolean {
	const n = narrow(c);
	return n;
}
function showBox(u: Box | string | boolean): string {
	if (u instanceof Box) return "Box " + u.n;
	if (typeof u === "string") return "string " + u;
	return "boolean";
}
function crate(): Crate | string {
	return new Crate(6);
}
function box(c: int32): Box | string {
	return c == 0 ? new Box(3) : "t";
}
function showList(u: string | int32[] | boolean): string {
	if (typeof u === "string") return "string " + u;
	if (typeof u === "boolean") return "boolean";
	return "array " + u.length;
}
function list(c: int32): string | int32[] {
	if (c == 0) return [1, 2, 3];
	return "x" + c;
}
function showN(u: int32 | string | boolean | null): string {
	if (u === null) return "null";
	if (typeof u === "string") return "string " + u;
	if (typeof u === "boolean") return "boolean";
	return "int32 " + u;
}
function nullable(c: int32): int32 | string | null {
	if (c == 0) return null;
	return c == 1 ? "s" : 5;
}
function takeNarrow(x: int32 | string): string {
	return typeof x === "string" ? "string " + x : "int32 " + x;
}
function narrowedRead(c: int32): string {
	let u: int32 | string | boolean = true;
	if (c == 1) { u = "s"; } else if (c == 2) { u = 3; }
	if (typeof u !== "boolean") {
		const kept = u;
		return takeNarrow(u) + "/" + takeNarrow(kept);
	}
	return "boolean";
}
interface Slot {
	value: int32 | string | boolean;
}
function inSlot(c: int32): Slot {
	return { value: narrow(c) };
}
function inList(c: int32): (int32 | string | boolean)[] {
	return [narrow(c), true];
}
const out: string[] = [];
for (let c = 0; c < 3; c++) out.push(show(stored(c)));
out.push(show(wide(0)));
out.push(show(narrow(1)));
let w: int32 | string | boolean = false;
out.push(show(w));
w = narrow(1);
out.push(show(w));
out.push(showBox(box(0)));
out.push(showBox(box(1)));
out.push(showBox(crate()));
const holders: Holder[] = [{ u: "f" }, { u: 8 }];
for (const h of holders) {
	const held: int32 | string | boolean = h.u;
	out.push(show(held));
}
for (let c = 0; c < 3; c++) out.push(showList(list(c)));
const picked: int32 | string = 5;
const back: int32 | string | boolean = picked;
out.push(show(back));
for (let c = 0; c < 3; c++) out.push(showN(nullable(c)));
for (let c = 0; c < 3; c++) out.push(narrowedRead(c));
const optional: int32 | string | boolean | null = narrow(1);
out.push(showN(optional));
out.push(showN(narrow(0) as int32 | string | boolean | null));
out.push(show(inSlot(1).value) + "," + show(inList(0)[0]) + "," + show(inList(0)[1]));
console.log(out.join("|"));
