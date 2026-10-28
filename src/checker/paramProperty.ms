import { Node, NodeKind, NodeFlag, createNodeAt, PropertyDeclData, ConstructorDeclData } from "../ast/node";
import { cloneNodeForCheck } from "../monomorphize/clone";

const accessPrefixes = ["public:", "private:", "protected:"];
const readonlyPrefix = "readonly:";

function constructorOf(body: Node[]): Node | null {
	for (const m of body) {
		if (m.kind == NodeKind.ConstructorDecl) return m;
	}
	return null;
}

// The index of the constructor parameter that declares `field`, or -1 for a field written in the class
// body: a parameter property sits at its parameter's source location, where no written member can.
export function paramPropertyIndex(field: Node, body: Node[]): number {
	const ctor = constructorOf(body);
	if (ctor == null || ctor.paramLocations == null || field.kind != NodeKind.PropertyDecl) return -1;
	const at = (ctor.data as ConstructorDeclData).ctorParams.indexOf((field.data as PropertyDeclData).propName);
	if (at < 0 || at >= ctor.paramLocations.length) return -1;
	const loc = ctor.paramLocations[at];
	if (loc.line != field.location.line || loc.column != field.location.column) return -1;
	return at;
}

export function hasParamProperties(ctor: Node): boolean {
	for (const name of (ctor.data as ConstructorDeclData).ctorParams) {
		for (const p of accessPrefixes) { if (name.startsWith(p)) return true; }
		if (name.startsWith(readonlyPrefix)) return true;
	}
	return false;
}

// A constructor parameter written `private readonly x: T` declares the field `x`; the parser keeps
// the modifiers as name prefixes so the formatter prints what was written. The fields come first
// among the members and are found again by paramPropertyIndex: ctorLower assigns them before any field
// initializer, and the unassigned-field check counts the constructor as assigning them.
export function expandParamProperties(body: Node[]): Node[] {
	const ctor = constructorOf(body);
	if (ctor == null || !hasParamProperties(ctor)) return body;
	const cd = ctor.data as ConstructorDeclData;
	const fields: Node[] = [];
	for (let i = 0; i < cd.ctorParams.length; i += 1) {
		let name = cd.ctorParams[i];
		let visibility = "";
		let isReadonly = false;
		let more = true;
		while (more) {
			more = false;
			for (const p of accessPrefixes) {
				if (name.startsWith(p)) {
					visibility = p.slice(0, p.length - 1);
					name = name.slice(p.length, name.length);
					more = true;
				}
			}
			if (name.startsWith(readonlyPrefix)) {
				isReadonly = true;
				name = name.slice(readonlyPrefix.length, name.length);
				more = true;
			}
		}
		if (name == cd.ctorParams[i]) continue;
		const loc = ctor.paramLocations != null && i < ctor.paramLocations.length ? ctor.paramLocations[i] : ctor.location;
		const field = createNodeAt(NodeKind.PropertyDecl, {
			propName: name, propType: cd.ctorParamTypes[i], propIsStatic: false, propIsReadonly: isReadonly,
			propVisibility: visibility, propInitializer: null as unknown as Node,
		}, loc);
		const typeExpr = ctor.typeExprs != null && i < ctor.typeExprs.length ? ctor.typeExprs[i] : null;
		if (typeExpr != null) field.typeExpr = typeExpr.flags.has(NodeFlag.BoundSym) ? typeExpr : cloneNodeForCheck(typeExpr);
		fields.push(field);
		cd.ctorParams[i] = name;
	}
	return fields.concat(body);
}
