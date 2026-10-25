// @stdout: 6|6|2|3|4|5|-1|4|4|15
// note: a union narrowed to one variant, a reference union or a TS-style object union, through a local or a field,, by its initializer, by an `if` on the discriminant or inside a `match` arm, still calls the extensions declared on the union.
import { JsonKind, JsonValue } from "std/serialize/json/types";

enum Kind { Lin, Poly }
type Value = match (kind: Kind) {
	Kind.Lin => { start: float32 },
	Kind.Poly => { values: Vec<float32> },
};
function evaluate(this v: Value, time: float32): float32 {
	return match (v.kind) {
		Kind.Lin => v.start * time,
		Kind.Poly => v.values.length as float32,
	};
}
function count(this v: Value): int32 {
	return match (v.kind) {
		Kind.Lin => 1,
		Kind.Poly => v.values.length as int32,
	};
}

function viaParam(v: Value): float32 { return v.evaluate(2.0); }
function viaIf(v: Value): int32 {
	if (v.kind == Kind.Poly) return v.count();
	return 0;
}
function viaMatch(v: Value): int32 {
	return match (v.kind) {
		Kind.Lin => v.count() * 3,
		Kind.Poly => v.count() + 1,
	};
}
type Shape = { kind: "sq", s: number } | { kind: "ci", r: number };
function area(this sh: Shape): number {
	if (sh.kind === "sq") return sh.s * sh.s;
	return sh.r * 3;
}
type Holder = { v: Shape };
function shapeViaIf(sh: Shape): number {
	if (sh.kind === "sq") return sh.area();
	return 0;
}
function shapeViaField(h: Holder): number {
	if (h.v.kind === "ci") return h.v.area();
	return 0;
}
function firstJson(v: JsonValue): number {
	if (v.kind == JsonKind.Array) return v.at(0).asNumber();
	return -1;
}

const lin: Value = { kind: Kind.Lin, start: 3.0 };
const poly: Value = { kind: Kind.Poly, values: [1.0, 2.0] };
const parts: string[] = [`${viaParam(lin)}`, `${lin.evaluate(2.0)}`, `${viaIf(poly)}`, `${viaMatch(lin)}`,
	`${viaMatch({ kind: Kind.Poly, values: [1.0, 2.0, 3.0] })}`];
const parsed = JSON.parseValue("[5, 6]");
if (parsed.ok) parts.push(`${firstJson(parsed.value)}`);
const scalar = JSON.parseValue("7");
if (scalar.ok) parts.push(`${firstJson(scalar.value)}`);
const sq: Shape = { kind: "sq", s: 2 };
parts.push(`${shapeViaIf(sq)}`);
parts.push(`${sq.area()}`);
parts.push(`${shapeViaField({ v: { kind: "ci", r: 5 } })}`);
console.log(parts.join("|"));
