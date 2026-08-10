// @stdout: stringify m=$7 p=(1,2) t=#hot tmpl=$7/#hot acc=p=(1,2) many=$7 p=(1,2)
// note: parity program — the two backends used to disagree here. Implicit
// stringification of a user type was planted after the checker by a C-only pass
// (stringConcatFlatten), so the synthesized `x.toString()` carried no symbol:
// C printed it as a struct member call (clang error) while JS never ran the pass
// at all and fell through to its own `+` coercion — right by luck for a class
// METHOD, silently "[object Object]" for an extension-declared toString. The
// insertion now happens at check time (reference: sigmatch localConvMatch), so
// both lanes bind the same declaration.

class Money {
	amount: number;
	constructor(a: number) { this.amount = a; }
	toString(): string { return "$" + this.amount.toString(); }
}

class Point {
	x: number;
	y: number;
	constructor(x: number, y: number) { this.x = x; this.y = y; }
}

function toString(this p: Point): string { return "(" + p.x.toString() + "," + p.y.toString() + ")"; }

interface Tag { name: string; }

function toString(this t: Tag): string { return "#" + t.name; }

function main(): void {
	const m = new Money(7);
	const p = new Point(1, 2);
	const t: Tag = { name: "hot" };

	const two = "" + m;
	const ext = "" + p;
	const iface = "" + t;
	const tmpl = `${m}/${t}`;
	let acc = "p=";
	acc += p;
	const many = "" + m + " p=" + p;

	console.log("stringify m=" + two + " p=" + ext + " t=" + iface + " tmpl=" + tmpl + " acc=" + acc + " many=" + many);
}

main();
