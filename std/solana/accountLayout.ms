import {
	EnumDeclData,
	IdentifierData,
	Node,
	NodeKind,
	TypeArrayData,
	TypeGenericData,
	TypeKind,
	TypeObjectData,
	getAlign,
	getOffset,
	getSize,
	getTypeImpl,
	typeKind,
} from "std/meta";

// Compile-time only: codecs and proof validation share the compiler's wire layout.
export struct AccountLayout {
	type: Node;
	kind: string;
	size: int32;
	align: int32;
	names: string[];
	offsets: int32[];
	children: AccountLayout[];
	count: int32;
	values: int32[];
}

function layoutError(type: Node, path: string, reason: string): never {
	throw new Error("SOLANA_ACCOUNT_FIELD: '" + path + "' " + reason);
}

function layoutOf(type: Node, path: string): AccountLayout {
	const originalKind = typeKind(type);
	if (originalKind == TypeKind.Ref || originalKind == TypeKind.Ptr ||
		originalKind == TypeKind.Borrow || originalKind == TypeKind.Span ||
		originalKind == TypeKind.Array || originalKind == TypeKind.String ||
		originalKind == TypeKind.CString || originalKind == TypeKind.Function ||
		originalKind == TypeKind.Union || originalKind == TypeKind.Result) {
		layoutError(type, path, "is not a wire value; use sized numbers, booleans, enums, structs or fixed arrays");
	}
	const impl = getTypeImpl(type);
	if (impl == null) { layoutError(type, path, "has no resolved wire type"); }
	const size = getSize(type);
	const align = getAlign(type);
	if (size < 0 || align <= 0) { layoutError(type, path, "has no compiler-calculated layout"); }
	let layout: AccountLayout = {
		type: type, kind: "", size: size, align: align,
		names: [], offsets: [], children: [], count: 0, values: [],
	};
	if (impl.kind == NodeKind.TypeGeneric) {
		const generic = impl as TypeGenericData;
		if (generic.typExprBase.kind == NodeKind.Identifier && generic.typExprArgs.length == 1) {
			const name = (generic.typExprBase as IdentifierData).name;
			if (name == "BitSet" && originalKind == TypeKind.Set) {
				layout.kind = "bitset";
				return layout;
			}
			if (name == "Distinct") {
				const child = layoutOf(generic.typExprArgs[0], path);
				if (size != child.size || align != child.align) {
					layoutError(type, path, "has a distinct representation inconsistent with its underlying layout");
				}
				layout.kind = "distinct";
				layout.children.push(child);
				return layout;
			}
		}
	}
	if (impl.kind == NodeKind.TypeObject) {
		const fields = impl as TypeObjectData;
		layout.kind = "struct";
		for (let i = 0; i < fields.typExprFieldNames.length; i += 1) {
			const name = fields.typExprFieldNames[i];
			const offset = getOffset(type, name);
			const child = layoutOf(fields.typExprFieldTypes[i], path + "." + name);
			if (offset < 0 || offset > size || child.size > size - offset) {
				layoutError(type, path + "." + name, "has no bounded compiler-calculated field offset");
			}
			layout.names.push(name);
			layout.offsets.push(offset);
			layout.children.push(child);
		}
		return layout;
	}
	if (impl.kind == NodeKind.TypeArray) {
		const array = impl as TypeArrayData;
		if (array.typExprSize < 0) { layoutError(type, path, "must have a fixed array length"); }
		const child = layoutOf(array.typExprElement, path + "[]");
		layout.kind = "array";
		layout.count = array.typExprSize as int32;
		if ((layout.count as int64) * (child.size as int64) != (size as int64)) {
			layoutError(type, path, "has an array layout inconsistent with its element stride");
		}
		layout.children.push(child);
		return layout;
	}
	if (impl.kind == NodeKind.EnumDecl) {
		const members = impl as EnumDeclData;
		if (members.enumMembers.length == 0) { layoutError(type, path, "is an enum with no valid values"); }
		if (size != 1 && size != 2 && size != 4) {
			layoutError(type, path, "has an unsupported enum storage width");
		}
		layout.kind = "enum";
		for (let i = 0; i < members.enumMembers.length; i += 1) {
			const value = members.enumValues.length == members.enumMembers.length ? members.enumValues[i] as int32 : i;
			layout.values.push(value);
		}
		return layout;
	}
	if (impl.kind == NodeKind.Identifier) {
		const name = (impl as IdentifierData).name;
		const numeric = match (name) {
			"int8" | "uint8" | "int16" | "uint16" | "int32" | "uint32" |
			"int64" | "uint64" | "float32" | "float64" | "number" => true,
			_ => false,
		};
		if (numeric || name == "boolean") { layout.kind = name; return layout; }
	}
	layoutError(type, path, "is not a sized number, boolean, enum, struct or fixed array");
}

export function accountLayout(type: Node): AccountLayout {
	const layout = layoutOf(type, "account");
	if (layout.kind != "struct") { layoutError(type, "account", "must be a struct"); }
	return layout;
}

export function requireZeroAccountLayout(layout: AccountLayout): void {
	if (layout.kind == "array" && layout.count == 0) { return; }
	if (layout.kind == "enum") {
		for (const value of layout.values) { if (value == 0) { return; } }
		throw new Error("SOLANA_ACCOUNT_ZERO: a newly created account's enum must contain zero before a typed proof can be returned");
	}
	for (const child of layout.children) { requireZeroAccountLayout(child); }
}
