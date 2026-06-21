// Native DRC stress for the JSX lexer (src/lexer/jsx.ms). Runs lex() 200k times on a JSX
// string that exercises every mode — apostrophe text, attribute, expr container, nested
// element, self-close. The lexer allocates per call (byteSlice for text/idents, jsxStack
// push/pop, the token array); flat RSS proves every allocation is freed under the C runtime.
// A wrong token stream (e.g. the apostrophe regressing to an unterminated-string choke)
// changes acc and fails expectStdout — so this also guards correctness natively.

import { lex } from "../../../lexer/lexer";
import { TokenKind } from "../../../lexer/token";

function countJsxTokens(src: string): number {
	const lr = lex(src);
	if (!lr.ok) return 0;
	let n = 0;
	for (const t of lr.value) {
		const k = t.kind;
		if (k === TokenKind.JsxTagStart || k === TokenKind.JsxClose || k === TokenKind.JsxText) {
			n = n + 1;
		}
	}
	return n;
}

function main(): void {
	let acc = 0;
	for (let i = 0; i < 200000; i = i + 1) {
		acc = (acc + countJsxTokens("<View id=\"x\">Don't {a}<b/></View>")) % 1000000;
	}
	console.log(`jsx-lex-native acc=${acc}`);
}
main();
