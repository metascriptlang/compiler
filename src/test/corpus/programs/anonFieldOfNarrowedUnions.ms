// @stdout: string: true
// @stdout: enum: true
// @stdout: match: true
// @stdout: boolean: true
enum K { A, B, C }

type Shape = { kind: "a", r: string } | { kind: "b", w: string } | { kind: "c", z: string };
type Tagged = { kind: K.A, r: string } | { kind: K.B, w: string } | { kind: K.C, z: string };
type Matched = match (kind: K) {
	K.A => { r: string },
	K.B => { w: string },
	K.C => { z: string },
};
type Flag = { ok: true, a: string } | { ok: false, b: string };

function makeShape(): Shape { return { kind: "b", w: "wide" }; }
function makeTagged(): Tagged { return { kind: K.B, w: "wide" }; }
function makeMatched(): Matched { return { kind: K.B, w: "wide" }; }
function makeFlag(): Flag { return { ok: true, a: "x" }; }

function shape(): string {
	const s = makeShape();
	if (s.kind != "a") {
		const o = { s: s };
		return "string: " + (o.s.kind == "b");
	}
	return "";
}

function tagged(): string {
	const t = makeTagged();
	if (t.kind != K.A) {
		const o = { s: t };
		return "enum: " + (o.s.kind == K.B);
	}
	return "";
}

function matched(): string {
	const m = makeMatched();
	if (m.kind != K.A) {
		const o = { s: m };
		return "match: " + (o.s.kind == K.B);
	}
	return "";
}

function flag(): string {
	const f = makeFlag();
	if (f.ok) {
		const o = { s: f };
		return "boolean: " + o.s.ok;
	}
	return "";
}

console.log(shape());
console.log(tagged());
console.log(matched());
console.log(flag());
