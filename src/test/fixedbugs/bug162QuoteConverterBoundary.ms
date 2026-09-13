// bug162 — a quote block at a typed boundary was never offered to the converter
// Symptom: with a converter targeting `number` in scope, `const v: number = <x/>` lowered but
//          `const v: number = quote { 1 + 1 }` reported "quote expression must be consumed by a
//          macro", even though both produce a compile-time Node and both positions are errors
//          without a converter.
// Root cause: checkExprInner routed QuoteExpr through the shared `noneType()` arm with
//             RegexLiteral and JSXText, so tryConverterAtBoundary ran for JSX literals only —
//             narrower than LANG.md's converter rule 1, which admits any compile-time-only source.
// Fix: QuoteExpr gets the same boundary arm as JSXElement/JSXFragment.
// Left open (pre-existing, unchanged by this fix and measured identical on the previous binary): a quote
// that finds no converter raises no checker diagnostic at all — unlike JSX, which has reportUnconsumedJsx —
// so it reaches the C backend and fails there ('expected expression'). That case has no cell here:
// compileToCWithStd stops before the C compiler, so a codegen-stage failure reads as success.

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

test "bug162: a quote block lowers through the converter at a declaration" {
	assert errorsOf("function main(): void { const v: number = quote { 1 + 1 }; console.log(v); }") == "";
}

test "bug162: a quote block lowers at a nullable slot and as an argument" {
	assert errorsOf("function main(): void { const v: number | null = quote { 1 }; console.log(v); }") == "";
	assert errorsOf("function take(v: number): void { console.log(v); } function main(): void { take(quote { 1 }); }") == "";
}
