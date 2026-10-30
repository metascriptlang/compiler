// @stdout: "$5"
// @stdout: [3,4]
// @stdout: {"m":"$5","p":[1,2],"n":null}
// @stdout: ["$1","$2"]
// @stdout: {"v":7}
// @stdout: {"cents":9}
// @stdout: {"m":"$5"}
// @stdout: {"label":"plain","t":{"n":1}}
// @stdout: ["$8",null]
// note: JSON.stringify calls a declared zero-argument `toJSON` on a value of its static type (class method or extension), top level, field or array element, and serializes the result; the result's own `toJSON` is not called again (ECMAScript SerializeJSONProperty), but its fields' are. A type declaring only `toString` serializes its fields as before. Same output on every lane.
class Money {
	cents: int32;
	constructor(c: int32) { this.cents = c; }
	toJSON(this: Readonly<Money>): string { return "$" + this.cents.toString(); }
}
struct Pt { x: int32; y: int32 }
function toJSON(this p: Pt): number[] { return [p.x, p.y]; }
interface Inner { v: int32 }
class Box {
	v: int32;
	constructor(v: int32) { this.v = v; }
	toJSON(): Inner { return { v: this.v }; }
}
class Chained {
	toJSON(): Money { return new Money(9); }
}
interface Holder { m: Money }
class Outer {
	toJSON(): Holder { return { m: new Money(5) }; }
}
class Spelled {
	n: int32;
	constructor(n: int32) { this.n = n; }
	toString(): string { return "spelled"; }
}
interface Wrap { m: Money; p: Pt; n: Money | null }
interface Plain { label: string; t: Spelled }

function main(): void {
	const m = new Money(5);
	console.log(JSON.stringify(m));
	console.log(JSON.stringify({ x: 3, y: 4 } as Pt));
	const w: Wrap = { m: m, p: { x: 1, y: 2 }, n: null };
	console.log(JSON.stringify(w));
	const ms: Money[] = [new Money(1), new Money(2)];
	console.log(JSON.stringify(ms));
	console.log(JSON.stringify(new Box(7)));
	console.log(JSON.stringify(new Chained()));
	console.log(JSON.stringify(new Outer()));
	const pl: Plain = { label: "plain", t: new Spelled(1) };
	console.log(JSON.stringify(pl));
	const opt: (Money | null)[] = [new Money(8), null];
	console.log(JSON.stringify(opt));
}
main();
