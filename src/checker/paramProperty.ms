import { Node, NodeKind, NodeFlag, createNodeAt, PropertyDeclData, ConstructorDeclData } from "../ast/node";
import { cloneNodeForCheck } from "../monomorphize/clone";
import { isCtorSignature } from "./ctorRoutine";

function constructorOf(body: Node[]): Node | null {
	for (const m of body) {
		if (m.kind == NodeKind.ConstructorDecl && !isCtorSignature(m)) return m;
	}
	return null;
}

export function isParamProperty(member: Node): boolean {
	return member.kind == NodeKind.PropertyDecl && member.flags.has(NodeFlag.ParamProperty);
}

export function hasParamProperties(ctor: Node): boolean {
	for (const p of (ctor.data as ConstructorDeclData).ctorParamProps) {
		if (p != null) return true;
	}
	return false;
}

// A constructor parameter written `private readonly x: T` declares the field `x`. The fields come
// first among the members; ctorLower assigns them before any field initializer, and the
// unassigned-field check counts the constructor as assigning them. A body cloned from an
// expanded class already holds them.
export function expandParamProperties(body: Node[]): Node[] {
	const ctor = constructorOf(body);
	if (ctor == null || !hasParamProperties(ctor)) return body;
	for (const m of body) {
		if (isParamProperty(m)) return body;
	}
	const cd = ctor.data as ConstructorDeclData;
	const fields: Node[] = [];
	for (let i = 0; i < cd.ctorParamProps.length; i += 1) {
		const written = cd.ctorParamProps[i];
		if (written == null) continue;
		const mods = written.data as PropertyDeclData;
		const field = createNodeAt(NodeKind.PropertyDecl, {
			propName: cd.ctorParams[i], propType: cd.ctorParamTypes[i], propIsStatic: false, propIsReadonly: mods.propIsReadonly,
			propVisibility: mods.propVisibility, propInitializer: null as unknown as Node,
		}, written.location);
		field.flags = field.flags.incl(NodeFlag.ParamProperty);
		const typeExpr = ctor.typeExprs != null && i < ctor.typeExprs.length ? ctor.typeExprs[i] : null;
		if (typeExpr != null) field.typeExpr = typeExpr.flags.has(NodeFlag.BoundSym) ? typeExpr : cloneNodeForCheck(typeExpr);
		fields.push(field);
	}
	return fields.concat(body);
}
