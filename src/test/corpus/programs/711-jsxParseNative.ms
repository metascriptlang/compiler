// @maxrss: 40
// @stdout: jsx-parse-native acc=5000
// @skip-js: migrated from native/ — JS-lane audit pending
// note: JSX parser (src/parser/expressions/jsx.ms) CRASH + CORRECTNESS guard: lex()+parseExpression() 5000× building a 3-child JSXElement (text + expr container + nested element), asserting the AST shape under the C runtime — catches over-free / UAF in JSX node construction (jsxChildren / jsxAttrs arrays, Result/try temporaries, nested nodes) that a type-level test cannot observe. NOT a leak guard: parseExpression accumulates per call regardless of JSX (A/B-proven — a plain `a + b * c` expr leaks the same ~2.7KB/iter; the parser frees per-compilation memory at process exit, not per call), so iterations are capped at 5000 (~14MB baseline) and the 40MB bound rides it while still catching a large JSX-specific leak on top. jsxLexNative is the leak guard.

// Native CRASH + CORRECTNESS guard for the JSX parser (src/parser/expressions/jsx.ms).
// Runs lex() + parseExpression() 5000 times on a JSX expression with a text child, an expr
// container, and a nested element, asserting it builds a 3-child JSXElement under the C
// runtime — catches over-free / UAF in JSX node construction (jsxChildren / jsxAttrs arrays,
// Result/try temporaries, nested nodes) that a type-level test cannot observe.
//
// NOT a leak guard: parseExpression accumulates per call (the parser, like most compiler
// front-ends, frees per-compilation memory at process exit, not per call — confirmed
// non-JSX-specific by A/B, a plain `a+b*c` expression leaks the same in a loop). The RSS bound
// is loose to ride that baseline; jsxLexNative is the JSX leak guard (the lexer is stateless).
// Iterations are capped so the per-call baseline stays bounded while still exercising the JSX
// node DRC path thousands of times.

import { lex } from "../../../lexer/lexer";
import { parseExpression } from "../../../parser/expressions/core";
import { NodeKind, JSXElementData } from "../../../ast/node";

function parseJsxChildCount(src: string): number {
	const lr = lex(src);
	if (!lr.ok) return -1;
	const pr = parseExpression(lr.value);
	if (!pr.ok) return -1;
	if (pr.value.kind !== NodeKind.JSXElement) return -1;
	const d = pr.value.data as JSXElementData;
	return d.jsxChildren.length;
}

function main(): void {
	let acc = 0;
	for (let i = 0; i < 5000; i = i + 1) {
		if (parseJsxChildCount("<p>hi {a}<b/></p>") === 3) {
			acc = (acc + 1) % 1000000;
		}
	}
	console.log(`jsx-parse-native acc=${acc}`);
}
main();
