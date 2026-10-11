// @stdout: repro=yes,-2 order=no,-5 alias=yes,-3 nested=yes,-7 nullable=no,null bool=true single=yes,-4 singleF=no,s du=ok 3|err e match=on,off
// note: `true | false` is `boolean`, so a union that holds both literals stores either value in one boolean member and `typeof`, `match` and `as` read it back; a union with only one of the two keeps that literal member.

type TF = true | false;
type FalseOrInt = false | int32;
type Outcome = { ok: true, v: int32 } | { ok: false, e: string };

function repro(x: int32): true | false | int32 { return x > 0 ? true : x; }
function order(x: int32): int32 | false | true { return x > 0 ? false : x; }
function alias(x: int32): TF | int32 { return x > 0 ? true : x; }
function nested(x: int32): true | FalseOrInt { return x > 0 ? true : x; }
function nullable(x: int32): true | false | null { return x > 0 ? false : null; }
function fromBoolean(b: boolean): true | false { return b; }
function single(x: int32): true | int32 { return x > 0 ? true : x; }
function singleFalse(x: int32): false | string { return x > 0 ? false : "s"; }
function outcome(x: int32): Outcome { return x > 0 ? { ok: true, v: x } : { ok: false, e: "e" }; }

function shown(v: boolean | int32): string {
	if (typeof v === "boolean") return v ? "yes" : "no";
	return String(v);
}
function shownSingle(v: true | int32): string {
	if (typeof v === "boolean") return v ? "yes" : "no";
	return String(v);
}
function shownFalse(v: false | string): string {
	if (typeof v === "boolean") return v ? "yes" : "no";
	return v;
}
function shownNullable(v: true | false | null): string {
	if (v == null) return "null";
	return v ? "yes" : "no";
}
function shownOutcome(o: Outcome): string {
	if (o.ok) return `ok ${o.v}`;
	return `err ${o.e}`;
}
function onOff(b: TF): string {
	return match (b) {
		true => "on",
		false => "off",
	};
}

const line = [
	`repro=${shown(repro(1))},${shown(repro(-2))}`,
	`order=${shown(order(1))},${shown(order(-5))}`,
	`alias=${shown(alias(1))},${shown(alias(-3))}`,
	`nested=${shown(nested(1))},${shown(nested(-7))}`,
	`nullable=${shownNullable(nullable(1))},${shownNullable(nullable(0))}`,
	`bool=${String(fromBoolean(true))}`,
	`single=${shownSingle(single(1))},${shownSingle(single(-4))}`,
	`singleF=${shownFalse(singleFalse(1))},${shownFalse(singleFalse(0))}`,
	`du=${shownOutcome(outcome(3))}|${shownOutcome(outcome(0))}`,
	`match=${onOff(true)},${onOff(false)}`,
];
console.log(line.join(" "));
