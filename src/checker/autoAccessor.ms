import { Node, NodeKind, NodeFlag, SourceLocation, createNodeAt, PropertyDeclData } from "../ast/node";
import { cloneNodeForCheck } from "../monomorphize/clone";

export function autoAccessorStorageName(name: string): string {
	return `${name}_accessor_storage`;
}

export function expandAutoAccessor(field: Node): Node[] {
	const pd = field.data as PropertyDeclData;
	const loc = field.location;
	const storageName = autoAccessorStorageName(pd.propName);
	const storage = createNodeAt(NodeKind.PropertyDecl, {
		propName: storageName, propType: pd.propType, propIsStatic: false, propIsReadonly: false,
		propVisibility: "private", propInitializer: pd.propInitializer,
	}, loc);
	storage.typeExpr = field.typeExpr;
	const getter = createNodeAt(NodeKind.MethodDecl, {
		methodName: `get_${pd.propName}`, methodParams: [], methodParamTypes: [],
		methodBody: createNodeAt(NodeKind.BlockStmt, { statements: [
			createNodeAt(NodeKind.ReturnStmt, { argument: storageRead(storageName, loc) }, loc),
		] }, loc),
		methodIsStatic: false, methodFlags: "", methodVisibility: pd.propVisibility, methodReturnType: pd.propType,
		methodDefaults: [], nativeName: "", nameLocation: loc,
	}, loc);
	getter.typeExpr = field.typeExpr == null ? null as unknown as Node : cloneNodeForCheck(field.typeExpr);
	getter.flags = getter.flags.incl(NodeFlag.Accessor);
	const setter = createNodeAt(NodeKind.MethodDecl, {
		methodName: `set_${pd.propName}`, methodParams: ["value"], methodParamTypes: [pd.propType],
		methodBody: createNodeAt(NodeKind.BlockStmt, { statements: [
			createNodeAt(NodeKind.ExprStmt, { expr: createNodeAt(NodeKind.BinaryExpr, {
				operator: "=", left: storageRead(storageName, loc), right: createNodeAt(NodeKind.Identifier, { name: "value" }, loc),
			}, loc) }, loc),
		] }, loc),
		methodIsStatic: false, methodFlags: "", methodVisibility: pd.propVisibility, methodReturnType: "",
		methodDefaults: [], nativeName: "", nameLocation: loc,
	}, loc);
	setter.typeExprs = field.typeExpr == null ? [] : [cloneNodeForCheck(field.typeExpr)];
	setter.paramLocations = [loc];
	setter.flags = setter.flags.incl(NodeFlag.Accessor);
	return [storage, getter, setter];
}

function storageRead(storageName: string, loc: SourceLocation): Node {
	return createNodeAt(NodeKind.MemberExpr, {
		object: createNodeAt(NodeKind.Identifier, { name: "this" }, loc), property: storageName, isOptional: false,
	}, loc);
}

export function isAutoAccessorField(member: Node): boolean {
	return member != null && member.kind == NodeKind.PropertyDecl && member.flags.has(NodeFlag.AutoAccessor);
}

export function expandAutoAccessors(body: Node[]): Node[] {
	let found = false;
	for (const m of body) {
		if (isAutoAccessorField(m)) found = true;
	}
	if (!found) return body;
	const out: Node[] = [];
	for (const m of body) {
		if (!isAutoAccessorField(m)) {
			out.push(m);
			continue;
		}
		for (const n of expandAutoAccessor(m)) out.push(n);
	}
	return out;
}
