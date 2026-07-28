// bug055 — getTypeArg(): the explicit <T> at a macro call site reaches the macro
//
// Gap: `getTypeImpl(Name)` (bug054) covers types the macro knows by name, but a
// codec-style macro needs the type the CALLER picked — `decode<User>(s)`. The
// type argument was believed unreachable ("MacroInvocationData has no slot"); in
// fact the parser stores it on the Node itself (`callNode.typeArg`, parser
// expressions/call.ms) and the CallExpr→MacroInvocation rewrite only replaces
// `node.data`, so it survives to expandMacroInvocation untouched.
//
// Contract: `getTypeArg()` in a macro body resolves the call site's <T> in the
// CALL SITE scope and splices its type-AST. Because the value differs per call
// site, the body is baked into a CLONE and the compiled-macro cache is keyed by
// (macro name, type argument) — otherwise the first instantiation would poison
// every later one.

import { compileToCWithStd } from "../helpers";

const macroSrc = `
import { Node, NodeKind } from "std/meta";

interface User { name: string; age: int32; }
interface Point { x: int32; y: int32; }

export macro fieldsOfT(x: Node): Node {
	const t = getTypeArg();
	let names: string = "";
	if (t.kind === NodeKind.TypeObject) {
		let i = 0;
		while (i < t.typExprFieldNames.length) {
			if (i > 0) { names = names + ","; }
			names = names + t.typExprFieldNames[i];
			i = i + 1;
		}
	}
	return { kind: NodeKind.StringLiteral, line: x.line, column: x.column, value: names };
}
`;

const srcOne = macroSrc + `
function main(): void {
	const a: string = fieldsOfT<User>(0);
	console.log(a);
}
`;

test "bug055: macro reads the call site's explicit type argument" {
	const c = compileToCWithStd(srcOne);
	assert c.ok;
	assert c.value.indexOf("name,age", 0) >= 0;
}

const srcTwo = macroSrc + `
function main(): void {
	const a: string = fieldsOfT<User>(0);
	const b: string = fieldsOfT<Point>(0);
	console.log(a);
	console.log(b);
}
`;

// The one that actually pins the cache key: with a name-only key the second
// instantiation would reuse the first's baked body and print "name,age" twice.
test "bug055: two instantiations of one macro stay independent" {
	const c = compileToCWithStd(srcTwo);
	assert c.ok;
	assert c.value.indexOf("name,age", 0) >= 0;
	assert c.value.indexOf("x,y", 0) >= 0;
}

const srcMissing = macroSrc + `
function main(): void {
	const a: string = fieldsOfT(0);
	console.log(a);
}
`;

test "bug055: getTypeArg() without an explicit type argument is a compile error" {
	const c = compileToCWithStd(srcMissing);
	assert !c.ok;
	assert c.error.indexOf("needs an explicit type argument", 0) >= 0;
}
