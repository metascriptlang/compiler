// bug159 — JSX at a nullable boundary found no converter
// Symptom: with a converter targeting `number` in scope, `const v: number | null = <x/>`,
//          an optional object field `{ fb?: number | null }` and a `number | null` parameter all
//          reported "JSX expression must be consumed by a macro … import a converter targeting
//          'Maybe_p…'": the lookup keyed on the Maybe wrapper, never on its payload.
// Root cause: tryConverterAtBoundary matched converter targets against the slot type as given,
//             and a nullable value slot is the Maybe struct, whose display name no converter declares.
// Fix: look the converter up by the Maybe payload, then re-check the expansion against the full
//      slot so the fit wraps the produced value like any `T → T | null` flow.

import { compileToCWithStd } from "../helpers";

const CONV = `
import { Node, NodeKind } from "std/meta";
export converter toNum(n: Node): number {
	return { kind: NodeKind.NumberLiteral, line: n.line, column: n.column, value: 7 };
}
`;

function errorsOf(body: string): string {
	const r = compileToCWithStd(CONV + body);
	if (r.ok) return "";
	return r.error;
}

test "bug159: JSX flows into a nullable declaration through the payload's converter" {
	assert errorsOf("function main(): void { const v: number | null = <x/>; console.log(v); }") == "";
}

test "bug159: JSX flows into an optional object field" {
	assert errorsOf("function take(p: { fb?: number | null }): void { console.log(p.fb); } function main(): void { take({ fb: <x/> }); }") == "";
}

test "bug159: JSX flows into a nullable parameter" {
	assert errorsOf("function take(v: number | null): void { console.log(v); } function main(): void { take(<x/>); }") == "";
}

test "bug159: a plain target still lowers and an unrelated nullable target still reports" {
	assert errorsOf("function main(): void { const n: number = <x/>; console.log(n); }") == "";
	assert errorsOf("function main(): void { const s: string | null = <x/>; console.log(s); }").contains("must be consumed by a macro");
}

test "bug159: a nullable slot reports the payload's name, never the Maybe wrapper" {
	const e = errorsOf("function main(): void { const s: string | null = <x/>; console.log(s); }");
	assert e.contains("targeting 'string'"), e;
	assert !e.contains("Maybe_"), e;
}

test "bug159: a pointer payload peels through the union representation too" {
	const REF = "class Box { v: number = 0; }\nexport converter toBox(n: Node): Box { return { kind: NodeKind.NumberLiteral, line: n.line, column: n.column, value: 7 }; }\n";
	const plain = errorsOf(REF + "function main(): void { const b: Box = <x/>; console.log(b); }");
	const nullable = errorsOf(REF + "function main(): void { const b: Box | null = <x/>; console.log(b); }");
	assert !plain.contains("must be consumed by a macro"), plain;
	assert !nullable.contains("must be consumed by a macro"), nullable;
}

test "bug159: a two-way union is refused and named as written" {
	const e = errorsOf("function main(): void { const v: number | string = <x/>; console.log(v); }");
	assert e.contains("must be consumed by a macro"), e;
	assert e.contains("targeting 'number | string'"), e;
}
