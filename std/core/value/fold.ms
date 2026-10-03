// Compile-time folds behind the std value routines: each expands, per instantiated type,
// into one step per field, element or variant.

import { Node, NodeKind, TypeKind, getType, getTypeImpl, typeKind, stringValue } from "std/meta";

export macro equalsFold(a: Node, b: Node): Node {
	const ln = a.line;
	const col = a.column;
	const field = (object: Node, name: string): Node => ({ kind: NodeKind.MemberExpr, line: ln, column: col, object: object, property: name, isOptional: false });
	const element = (array: Node, i: int32): Node => ({ kind: NodeKind.ArrayAccess, line: ln, column: col, array: array, index: { kind: NodeKind.NumberLiteral, line: ln, column: col, value: i, isFloat: false, intVal: i as int64, outOfRangeText: "", isBitPattern: false } });
	const unlessSame = (left: Node, right: Node): Node => ({ kind: NodeKind.IfStmt, line: ln, column: col,
		condition: { kind: NodeKind.UnaryExpr, line: ln, column: col, unaryOp: "!", operand: { kind: NodeKind.BinaryExpr, line: ln, column: col, operator: "==", left: left, right: right } },
		consequent: { kind: NodeKind.ReturnStmt, line: ln, column: col, argument: { kind: NodeKind.BooleanLiteral, line: ln, column: col, boolValue: false } } });
	const shallow = getType(a);
	if (shallow == null) error("equality of a type the compiler could not name", a);
	const isRef = shallow.kind == NodeKind.TypeGeneric && shallow.typExprBase.name == "Ref";
	const t = isRef ? null : getTypeImpl(a);
	const steps: Node[] = [];
	if (t != null && t.kind == NodeKind.TypeObject) {
		for (let i = 0; i < t.typExprFieldNames.length; i = i + 1) {
			const name = t.typExprFieldNames[i];
			steps.push(unlessSame(field(a, name), field(b, name)));
		}
	} else if (t != null && t.kind == NodeKind.TypeArray && t.typExprSize >= 0) {
		for (let i = 0; i < t.typExprSize; i = i + 1) {
			steps.push(unlessSame(element(a, i), element(b, i)));
		}
	} else if (t != null && t.kind == NodeKind.TypeGeneric && t.typExprBase.name == "tuple") {
		for (let i = 0; i < t.typExprArgs.length; i = i + 1) {
			steps.push(unlessSame(element(a, i), element(b, i)));
		}
	} else {
		error("no value equality for this type: only a struct, tuple, fixed array, nullable value or Result is compared by value", a);
	}
	return { kind: NodeKind.SpliceMany, line: ln, column: col, spliceNodes: steps };
}

function typeofTag(name: string): string {
	if (name == "string") return "string";
	if (name == "boolean") return "boolean";
	if (name == "int8" || name == "int16" || name == "int32" || name == "uint8" || name == "uint16" || name == "uint32" || name == "float32" || name == "float64" || name == "number") return "number";
	return "";
}

export macro dumpFold(x: Node, color: Node): Node {
	const ln = x.line;
	const col = x.column;
	const ident = (name: string): Node => ({ kind: NodeKind.Identifier, line: ln, column: col, name: name });
	const call = (name: string, args: Node[]): Node => ({ kind: NodeKind.CallExpr, line: ln, column: col, callee: ident(name), arguments: args });
	const lit = (text: string): Node => ({ kind: NodeKind.StringLiteral, line: ln, column: col, value: text });
	const field = (object: Node, name: string): Node => ({ kind: NodeKind.MemberExpr, line: ln, column: col, object: object, property: name, isOptional: false });
	const element = (array: Node, i: int32): Node => ({ kind: NodeKind.ArrayAccess, line: ln, column: col, array: array, index: { kind: NodeKind.NumberLiteral, line: ln, column: col, value: i, isFloat: false, intVal: i as int64, outOfRangeText: "", isBitPattern: false } });
	const append = (value: Node): Node => ({ kind: NodeKind.ExprStmt, line: ln, column: col,
		expr: { kind: NodeKind.BinaryExpr, line: ln, column: col, operator: "=", left: ident("out"),
			right: { kind: NodeKind.BinaryExpr, line: ln, column: col, operator: "+", left: ident("out"), right: value } } });
	const discriminated = (u: Node): boolean => {
		for (let i = 0; i < u.typExprMembers.length; i = i + 1) {
			const m = u.typExprMembers[i];
			if (m.kind != NodeKind.TypeGeneric || m.typExprBase.name != "Ref") return false;
			const v = m.typExprArgs[0];
			if (v.kind != NodeKind.TypeObject || v.typExprFieldNames.length == 0 || v.typExprFieldTypes[0].kind != NodeKind.StringLiteral) return false;
		}
		return u.typExprMembers.length > 0;
	};
	const primitiveOnly = (u: Node): boolean => {
		for (let i = 0; i < u.typExprMembers.length; i = i + 1) {
			if (u.typExprMembers[i].kind != NodeKind.Identifier) return false;
		}
		return u.typExprMembers.length > 0;
	};
	const shallow = getType(x);
	if (shallow == null) error("dump of a type the compiler could not name", x);
	const isRef = shallow.kind == NodeKind.TypeGeneric && shallow.typExprBase.name == "Ref";
	const opaque = isRef && shallow.typExprArgs[0].kind == NodeKind.TypeGeneric;
	const t = opaque ? null : getTypeImpl(x);
	const steps: Node[] = [];
	if (isRef && t != null && t.kind == NodeKind.TypeObject) {
		steps.push({ kind: NodeKind.IfStmt, line: ln, column: col,
			condition: { kind: NodeKind.BinaryExpr, line: ln, column: col, operator: "==", left: x, right: { kind: NodeKind.NullLiteral, line: ln, column: col } },
			consequent: { kind: NodeKind.ReturnStmt, line: ln, column: col, argument: call("nullText", [color]) } });
	}
	if (t != null && t.kind == NodeKind.TypeObject) {
		steps.push(append(call("openObject", [color])));
		for (let i = 0; i < t.typExprFieldNames.length; i = i + 1) {
			const name = t.typExprFieldNames[i];
			if (i > 0) steps.push(append(call("separator", [color])));
			steps.push(append(call("key", [lit(name), color])));
			steps.push(append(call("valueDump", [field(x, name), color])));
		}
		steps.push(append(call("closeObject", [color])));
	} else if (t != null && t.kind == NodeKind.TypeArray && t.typExprSize >= 0) {
		steps.push(append(lit("[")));
		for (let i = 0; i < t.typExprSize; i = i + 1) {
			if (i > 0) steps.push(append(call("separator", [color])));
			steps.push(append(call("valueDump", [element(x, i), color])));
		}
		steps.push(append(lit("]")));
	} else if (t != null && t.kind == NodeKind.TypeArray) {
		steps.push(append(call("arrayDump", [x, color])));
	} else if (t != null && t.kind == NodeKind.TypeGeneric && t.typExprBase.name == "tuple") {
		steps.push(append(lit("[")));
		for (let i = 0; i < t.typExprArgs.length; i = i + 1) {
			if (i > 0) steps.push(append(call("separator", [color])));
			steps.push(append(call("valueDump", [element(x, i), color])));
		}
		steps.push(append(lit("]")));
	} else if (t != null && t.kind == NodeKind.TypeUnion && t.typExprMembers.length == 2
		&& ((t.typExprMembers[0].kind == NodeKind.Identifier && t.typExprMembers[0].name == "null")
			|| (t.typExprMembers[1].kind == NodeKind.Identifier && t.typExprMembers[1].name == "null"))) {
		steps.push(append(call("nullableDump", [x, color])));
	} else if (t != null && t.kind == NodeKind.TypeUnion && discriminated(t)) {
		let chain: Node | null = null;
		for (let i = t.typExprMembers.length - 1; i >= 0; i = i - 1) {
			const variant = t.typExprMembers[i].typExprArgs[0];
			const disc = variant.typExprFieldNames[0];
			const test: Node = { kind: NodeKind.BinaryExpr, line: ln, column: col, operator: "==", left: field(x, disc), right: lit(stringValue(variant.typExprFieldTypes[0])) };
			const step: Node = { kind: NodeKind.BlockStmt, line: ln, column: col, statements: [append(call("valueDump", [x, color]))] };
			chain = chain == null
				? { kind: NodeKind.IfStmt, line: ln, column: col, condition: test, consequent: step }
				: { kind: NodeKind.IfStmt, line: ln, column: col, condition: test, consequent: step, alternate: chain };
		}
		steps.push(chain as Node);
	} else if (t != null && t.kind == NodeKind.TypeUnion && primitiveOnly(t)) {
		let chain: Node | null = null;
		for (let i = t.typExprMembers.length - 1; i >= 0; i = i - 1) {
			const tag = typeofTag(t.typExprMembers[i].name);
			if (tag == "") continue;
			const test: Node = { kind: NodeKind.BinaryExpr, line: ln, column: col, operator: "==", left: { kind: NodeKind.UnaryExpr, line: ln, column: col, unaryOp: "typeof", operand: x }, right: lit(tag) };
			const step: Node = { kind: NodeKind.BlockStmt, line: ln, column: col, statements: [append(call("valueDump", [x, color]))] };
			chain = chain == null
				? { kind: NodeKind.IfStmt, line: ln, column: col, condition: test, consequent: step }
				: { kind: NodeKind.IfStmt, line: ln, column: col, condition: test, consequent: step, alternate: chain };
		}
		if (chain != null) steps.push(chain as Node);
	} else if (t != null && t.kind == NodeKind.TypeUnion && t.typExprMembers.length == 2
		&& t.typExprMembers[0].kind == NodeKind.TypeObject && t.typExprMembers[0].typExprFieldNames.length > 0
		&& t.typExprMembers[0].typExprFieldNames[0] == "ok") {
		steps.push(append(call("resultDump", [x, color])));
	} else {
		const kind = typeKind(x);
		if (kind == TypeKind.String || kind == TypeKind.StringLiteral) {
			steps.push(append(call("textLeaf", [x, color])));
		} else if (kind == TypeKind.Boolean) {
			steps.push(append(call("boolLeaf", [x, color])));
		} else if (kind == TypeKind.Number || kind == TypeKind.Float32 || kind == TypeKind.Float64) {
			steps.push(append(call("numberLeaf", [x, color])));
		} else if (kind == TypeKind.Int8 || kind == TypeKind.Int16 || kind == TypeKind.Int32 || kind == TypeKind.Int64
			|| kind == TypeKind.Uint8 || kind == TypeKind.Uint16 || kind == TypeKind.Uint32 || kind == TypeKind.Uint64
			) {
			steps.push(append(call("integerLeaf", [x, color])));
		} else if (kind == TypeKind.Enum || kind == TypeKind.EnumLiteral) {
			steps.push(append(call("enumLeaf", [x, color])));
		} else if (kind == TypeKind.BigInt) {
			steps.push(append(call("bigintLeaf", [x])));
		} else {
			steps.push(append(call("nullText", [color])));
		}
	}
	return { kind: NodeKind.SpliceMany, line: ln, column: col, spliceNodes: steps };
}

export macro debugLabel(x: Node): Node {
	const shallow = getType(x);
	if (shallow == null) error("debug label of a type the compiler could not name", x);
	let color = "";
	let name = "";
	if (shallow.kind == NodeKind.TypeGeneric && shallow.typExprBase.name == "Ref") {
		const target = shallow.typExprArgs[0];
		color = "\x1b[32m";
		name = target.kind == NodeKind.Identifier ? target.name : (target.kind == NodeKind.TypeObject ? target.typExprTypeName : "");
	} else if (shallow.kind == NodeKind.TypeObject) {
		color = "\x1b[34m";
		name = shallow.typExprTypeName;
	} else if (shallow.kind == NodeKind.TypeGeneric && shallow.typExprBase.name != "tuple") {
		color = "\x1b[34m";
		name = shallow.typExprBase.name;
	}
	if (name.startsWith("__anon")) {
		color = "\x1b[36m";
		name = "Object";
	}
	const text = name == "" ? "" : color + name + " \x1b[0m";
	return { kind: NodeKind.StringLiteral, line: x.line, column: x.column, value: text };
}
