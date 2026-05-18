// AST Validator — post-check metadata verification
//
// Reference parity: sem IS the validation. Function bodies were type-checked by
// checkProgramBody/checkFunctionBody. This validator only catches missing
// nodeType on top-level identifier expressions (not inside function bodies).

import { Node, NodeKind, IdentifierData } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { CheckerContext, addError } from "./context";


export function validateTypedAST(ctx: CheckerContext, node: Node): void {
	if (node === null) return;

	// Skip function/method bodies — already validated by checkFunctionBody.
	// Skip macro bodies — they're handled by the macro VM, not the regular
	// type-checker, so their identifiers don't carry runtime nodeType.
	if (node.kind === NodeKind.FunctionDecl) return;
	if (node.kind === NodeKind.MethodDecl) return;
	if (node.kind === NodeKind.ConstructorDecl) return;
	if (node.kind === NodeKind.MacroDecl) return;

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
