// AST Validator — post-check metadata verification
//
// Nim parity: sem IS the validation. Function bodies were type-checked by
// checkProgramBody/checkFunctionBody. This validator only catches missing
// nodeType on top-level identifier expressions (not inside function bodies).

import { Node, NodeKind, IdentifierData } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { CheckerContext, addError } from "./context";


export function validateTypedAST(ctx: CheckerContext, node: Node): void {
	if (node === null) return;

	// Skip function bodies — already validated by checkFunctionBody/semProcBody
	if (node.kind === NodeKind.FunctionDecl) return;

	// Flag missing nodeType on non-type identifiers (critical for codegen)
	if (node.kind === NodeKind.Identifier && node.nodeType === null) {
		const d = node.data as IdentifierData;
		const first = d.name.length > 0 ? d.name.slice(0, 1) : "";
		if (first < "A" || first > "Z") {
			addError(ctx, `Internal Error: missing nodeType on Identifier '${d.name}' at line ${node.location.line}`, node.location.line, node.location.column);
		}
	}

	forEachChild(node, (child: Node): void => {
		validateTypedAST(ctx, child);
	});
}
