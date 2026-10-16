// @skip-js
// @stdout: {"x":1,"y":2} {"w":7} none $5 | $5 {"w":7} | Box(9) row 7 | {"x":1,"y":2}/$5 |
// @stdout: $5 Box(9) none
// note: a union of structs converts to text through the member its tag selects, by that member's own toString when it has one; JS stores no tag for these members, so the lane is skipped.
struct TextPoint { x: int32; y: int32 }
struct TextSize { w: int32 }
struct TextPrice { cents: int32 }

function toString(this p: TextPrice): string {
	return "$" + (p.cents / 100).toString();
}

class Box {
	v: int32;
	constructor(v: int32) { this.v = v; }
	toString(): string { return `Box(${this.v})`; }
}

function shape(k: int32): TextPoint | TextSize | TextPrice | string {
	if (k == 0) return { x: 1, y: 2 };
	if (k == 1) return { w: 7 };
	if (k == 3) return { cents: 500 } as TextPrice;
	return "none";
}

function held(k: int32): Box | string | int32 {
	if (k == 0) return new Box(9);
	if (k == 1) return "row";
	return 7;
}

function label<T>(v: T): string {
	return String(v);
}

const kept = shape(3);
const other = shape(1);
console.log(String(shape(0)), shape(1).toString(), String(shape(2)), String(shape(3)), "|",
	kept.toString(), label(other), "|", String(held(0)), String(held(1)), String(held(2)), "|",
	`${shape(0)}/${kept}`, "|");
console.log(kept, held(0), shape(2));
