// macroNodeBogusField — bad flat Node-field access in a macro body FAILS LOUD.
//
// Pre-fix the engine compile swallowed every checker error from macro-body
// wrappers (params untyped, errors discarded), so a typo'd field read compiled
// clean and expanded garbage silently. Post-fix the wrapper errors surface
// through getOrCompileMacro ("Macro '<name>' body: ..."), and an unnarrowed
// read of a field whose type differs across NodeData variants (value:
// number|string) demands narrowing per the DU access rule.
//
// GUARD-CHECK-FAIL does not exist
// GUARD-CHECK-FAIL different types across Node variants

import { Node, NodeKind } from "std/meta";

export macro mBogus(n: Node): Node {
	const z = n.totallyBogusFieldXyz;
	return { kind: NodeKind.StringLiteral, line: n.line, column: n.column, value: "x" };
}

export macro mAmbig(n: Node): Node {
	const v = n.value;
	return { kind: NodeKind.StringLiteral, line: n.line, column: n.column, value: "y" };
}

function main(): void {
	console.log(mBogus(<p class="box">hi</p>));
	console.log(mAmbig(<p class="box">hi</p>));
}
main();
