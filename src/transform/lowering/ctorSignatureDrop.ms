import { Node, NodeKind, ProgramData, ClassDeclData, ActorDeclData, DecoratedDeclData, ExportDeclData } from "../../ast/node";
import { TransformContext } from "../context";
import { isCtorSignature } from "../../checker/ctorRoutine";

function withoutSignatures(body: Node[]): Node[] {
	return body.filter((m: Node): boolean => !isCtorSignature(m.kind == NodeKind.DecoratedDecl ? (m.data as DecoratedDeclData).decoratedNode : m));
}

// A constructor signature is typecheck-only: the checker ranked it for a `new` and pointed the
// call at the implementation, so no lowering or emitter sees it as a constructor.
export function dropCtorSignatures(program: Node, ctx: TransformContext): Node {
	for (const stmt of (program.data as ProgramData).programStmts) {
		const target = stmt.kind == NodeKind.ExportDecl ? (stmt.data as ExportDeclData).exportedDecl : stmt;
		if (target == null) continue;
		if (target.kind == NodeKind.ClassDecl) {
			const cd = target.data as ClassDeclData;
			cd.classBody = withoutSignatures(cd.classBody);
		} else if (target.kind == NodeKind.ActorDecl) {
			const ad = target.data as ActorDeclData;
			ad.actorBody = withoutSignatures(ad.actorBody);
		}
	}
	return program;
}
