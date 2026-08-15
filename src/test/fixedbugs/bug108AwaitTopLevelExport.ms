// bug108 — top-level `export const x = await f()` survives lowering as raw AwaitExpr
//
// Symptom:    C compile error `expected expression` at `/* unsupported expression:
//             kind=AwaitExpr */` for any top-level exported const with an await
//             initializer, in entry and imported modules alike.
// Root cause: awaitLower expandStmt matched bare VariableDecl but never the
//             ExportDecl wrapper (src/transform/lowering/awaitLower.ms).
// Fix:        ExportDecl arm unwraps exportedDecl and runs the same initializer
//             expansion; hoisted stmts precede the export decl.

import { compileToCWithStd } from "../helpers";

test "bug108: top-level export const await lowers through the ExportDecl wrapper" {
	const src = `
async function g(): Promise<int32> { return 5; }
export const v = await g();
console.log("got " + v);
`;
	const c = compileToCWithStd(src);
	assert c.ok;
	const code = c.value;
	assert !code.includes("unsupported expression");
	assert code.includes("msWaitForReady");
}
