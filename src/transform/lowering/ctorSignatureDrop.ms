import { Node, NodeKind, ProgramData, ClassDeclData, ActorDeclData, DecoratedDeclData, ExportDeclData, Symbol, createNodeAt } from "../../ast/node";
import { TransformContext } from "../context";
import { cloneNodeKeepSem } from "../../monomorphize/clone";
import { isCtorSignature, ctorVariantsOf, ctorVariantDecl } from "../../checker/ctorRoutine";

function withoutSignatures(body: Node[]): Node[] {
	return body.filter((m: Node): boolean => !isCtorSignature(m.kind == NodeKind.DecoratedDecl ? (m.data as DecoratedDeclData).decoratedNode : m));
}

// A constructor signature is typecheck-only: the checker ranked it for a `new` and pointed the
// call at the implementation, or at the implementation checked with that signature's parameter
// types. That variant joins the class as one more constructor, a copy under the implementation's
// decorators, since lowering rewrites it in place; JS emits one constructor per class and runs the implementation.
function withVariants(body: Node[]): Node[] {
	for (const member of body) {
		const inner = member.kind == NodeKind.DecoratedDecl ? (member.data as DecoratedDeclData).decoratedNode : member;
		if (inner == null || inner.kind != NodeKind.ConstructorDecl) continue;
		const out = body.slice(0);
		for (const v of ctorVariantsOf(inner.resolvedSym)) out.push(asMember(member, v));
		return out;
	}
	return body;
}

function asMember(impl: Node, variant: Symbol): Node {
	const decl = cloneNodeKeepSem(ctorVariantDecl(variant));
	if (impl.kind != NodeKind.DecoratedDecl) return decl;
	const wrapped = createNodeAt(NodeKind.DecoratedDecl, { decorators: (impl.data as DecoratedDeclData).decorators, decoratedNode: decl }, decl.location);
	wrapped.flags = impl.flags;
	wrapped.resolvedSym = variant;
	return wrapped;
}

export function dropCtorSignatures(program: Node, ctx: TransformContext): Node {
	for (const stmt of (program.data as ProgramData).programStmts) {
		const target = stmt.kind == NodeKind.ExportDecl ? (stmt.data as ExportDeclData).exportedDecl : stmt;
		if (target == null) continue;
		if (target.kind == NodeKind.ClassDecl) {
			const cd = target.data as ClassDeclData;
			cd.classBody = withoutSignatures(cd.classBody);
			if (!ctx.jsBackend) cd.classBody = withVariants(cd.classBody);
		} else if (target.kind == NodeKind.ActorDecl) {
			const ad = target.data as ActorDeclData;
			ad.actorBody = withoutSignatures(ad.actorBody);
		}
	}
	return program;
}
