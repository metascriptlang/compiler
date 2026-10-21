// Object namespace — TS-style reflection over statically shaped values.
//
// MS objects (interface/struct/class instances) carry their shape at compile
// time, so keys/values resolve from the type-AST at monomorphization time:
// the static generic method body calls a macro on the value, the call defers
// while T is parametric (same mechanism as the codec pattern), and post-mono
// the macro walks the peeled shape and emits a plain array literal. Zero
// runtime reflection, both backends emit the same literal.
//
// values() requires every field to share one atomic type — MS arrays are
// homogeneous and generics cannot express `T[keyof T]`. Mixed-shape objects
// must read fields directly. entries() needs tuple element types — follow-up.

import { Node, NodeKind, getTypeImpl, sameType } from "std/meta";

export class Object {
	// Return type is fixed by the emitted literal: string[].
	static keys<T>(o: T): string[] {
		return objectKeysOf(o);
	}

	// No declared return: the element type is the fields' shared type, only
	// knowable after the macro expands against the concrete T.
	static values<T>(o: T) {
		return objectValuesOf(o);
	}
}

export function hash<T>(this x: Readonly<T>): int64 {
	return hashOf(x);
}

export macro hashOf(t: Node): Node {
	const tt = t.nodeType;
	const parts: Node[] = [];
	let nullable = false;
	if (tt.kind == NodeKind.TypeUnion) {
		for (const m of tt.typExprMembers) {
			if (m.kind == NodeKind.Identifier && m.name == "null") nullable = true;
		}
	}
	if (nullable) {
		const present: Node = {
			kind: NodeKind.BinaryExpr, line: t.line, column: t.column, operator: "!==", left: t,
			right: { kind: NodeKind.NullLiteral, line: t.line, column: t.column, nullPlaceholder: true },
		};
		const absent: Node = {
			kind: NodeKind.TypeAssertion, line: t.line, column: t.column, asType: "int64",
			asExpr: { kind: NodeKind.NumberLiteral, line: t.line, column: t.column, value: 0, isFloat: false, intVal: 0, outOfRangeText: "", isBitPattern: false },
		};
		const valueHash: Node = {
			kind: NodeKind.CallExpr, line: t.line, column: t.column,
			callee: { kind: NodeKind.MemberExpr, line: t.line, column: t.column, object: t, property: "hash", isOptional: false },
			arguments: [],
		};
		parts.push({ kind: NodeKind.ConditionalExpr, line: t.line, column: t.column, ternaryCondition: present, ternaryConsequent: valueHash, ternaryAlternate: absent });
		parts.push({
			kind: NodeKind.CallExpr, line: t.line, column: t.column,
			callee: { kind: NodeKind.MemberExpr, line: t.line, column: t.column, object: present, property: "hash", isOptional: false },
			arguments: [],
		});
	} else if (tt.kind == NodeKind.TypeGeneric && tt.typExprBase.name == "tuple") {
		let i = 0;
		while (i < tt.typExprArgs.length) {
			const element: Node = {
				kind: NodeKind.ArrayAccess, line: t.line, column: t.column, array: t,
				index: { kind: NodeKind.NumberLiteral, line: t.line, column: t.column, value: i, isFloat: false, intVal: i, outOfRangeText: "", isBitPattern: false },
			};
			parts.push({
				kind: NodeKind.CallExpr, line: t.line, column: t.column,
				callee: { kind: NodeKind.MemberExpr, line: t.line, column: t.column, object: element, property: "hash", isOptional: false },
				arguments: [],
			});
			i = i + 1;
		}
	} else {
		const shape = getTypeImpl(t);
		if (shape == null) error("hash: type implementation is unavailable", t);
		if (tt.kind == NodeKind.TypeGeneric && tt.typExprBase.name == "Ref") {
			return {
				kind: NodeKind.CallExpr, line: t.line, column: t.column,
				callee: { kind: NodeKind.Identifier, line: t.line, column: t.column, name: "hashPointer" },
				arguments: [{ kind: NodeKind.TypeAssertion, line: t.line, column: t.column, asExpr: t, asType: "Readonly<Ptr<void>>" }],
			};
		}
		let base = shape;
		let distinct = false;
		while (base.kind == NodeKind.TypeGeneric && base.typExprBase.name == "Distinct") {
			base = base.typExprArgs[0];
			distinct = true;
		}
		if (base.kind == NodeKind.EnumDecl) {
			const ordinal: Node = { kind: NodeKind.TypeAssertion, line: t.line, column: t.column, asExpr: t, asType: "int64" };
			return {
				kind: NodeKind.CallExpr, line: t.line, column: t.column,
				callee: { kind: NodeKind.Identifier, line: t.line, column: t.column, name: "hashWangYi1" },
				arguments: [{ kind: NodeKind.TypeAssertion, line: t.line, column: t.column, asExpr: ordinal, asType: "uint64" }],
			};
		}
		if (distinct) {
			const ordinals = ["int8", "int16", "int32", "int64", "uint8", "uint16", "uint32", "uint64", "char", "boolean"];
			if (base.kind != NodeKind.Identifier || ordinals.indexOf(base.name) < 0) {
				error("hash: a distinct key takes its base's hash only over an integer, char, boolean or enum — give it `hash(this k: K): int64`", t);
			}
			const asBase: Node = { kind: NodeKind.TypeAssertion, line: t.line, column: t.column, asExpr: t, asType: base.name };
			return {
				kind: NodeKind.CallExpr, line: t.line, column: t.column,
				callee: { kind: NodeKind.MemberExpr, line: t.line, column: t.column, object: asBase, property: "hash", isOptional: false },
				arguments: [],
			};
		}
		if (shape.kind != NodeKind.TypeObject) {
			error("hash: no hash for this key type — give it `hash(this k: K): int64`", t);
		}
		for (const f of shape.typExprFieldNames) {
			const field: Node = { kind: NodeKind.MemberExpr, line: t.line, column: t.column, object: t, property: f, isOptional: false };
			parts.push({
				kind: NodeKind.CallExpr, line: t.line, column: t.column,
				callee: { kind: NodeKind.MemberExpr, line: t.line, column: t.column, object: field, property: "hash", isOptional: false },
				arguments: [],
			});
		}
	}
	const zero: Node = { kind: NodeKind.NumberLiteral, line: t.line, column: t.column, value: 0, isFloat: false, intVal: 0, outOfRangeText: "", isBitPattern: false };
	let acc: Node = { kind: NodeKind.TypeAssertion, line: t.line, column: t.column, asExpr: zero, asType: "int64" };
	for (const partHash of parts) {
		acc = {
			kind: NodeKind.CallExpr, line: t.line, column: t.column,
			callee: { kind: NodeKind.Identifier, line: t.line, column: t.column, name: "hashCombine" },
			arguments: [acc, partHash],
		};
	}
	return {
		kind: NodeKind.CallExpr, line: t.line, column: t.column,
		callee: { kind: NodeKind.Identifier, line: t.line, column: t.column, name: "hashFinish" },
		arguments: [acc],
	};
}

export macro objectKeysOf(t: Node): Node {
	const tt = getTypeImpl(t);
	if (tt == null) error("Object.keys: type implementation is unavailable", t);
	if (tt.kind != NodeKind.TypeObject) {
		error("Object.keys: expected an object type (interface/struct/class) — primitives and arrays have no field shape", t);
	}
	const names: Node[] = [];
	const fields = tt.typExprFieldNames;
	let i = 0;
	while (i < fields.length) {
		names.push({
			kind: NodeKind.StringLiteral, line: t.line, column: t.column,
			value: fields[i],
		});
		i = i + 1;
	}
	return {
		kind: NodeKind.ArrayLiteral, line: t.line, column: t.column,
		elements: names,
	};
}

export macro objectValuesOf(t: Node): Node {
	const tt = getTypeImpl(t);
	if (tt == null) error("Object.values: type implementation is unavailable", t);
	if (tt.kind != NodeKind.TypeObject) {
		error("Object.values: expected an object type (interface/struct/class) — primitives and arrays have no field shape", t);
	}
	const fields = tt.typExprFieldNames;
	const types = tt.typExprFieldTypes;
	const vals: Node[] = [];
	let uniform: Node | null = null;
	let mixed = false;
	let i = 0;
	while (i < fields.length) {
		if (types[i].kind != NodeKind.Identifier) {
			mixed = true;
		} else if (uniform == null) {
			uniform = types[i];
		} else if (!sameType(uniform, types[i])) {
			mixed = true;
		}
		vals.push({
			kind: NodeKind.MemberExpr, line: t.line, column: t.column,
			object: t, property: fields[i], isOptional: false,
		});
		i = i + 1;
	}
	if (mixed) {
		error("Object.values: every field must share one atomic type — heterogeneous shapes must read fields directly", t);
	}
	return {
		kind: NodeKind.ArrayLiteral, line: t.line, column: t.column,
		elements: vals,
	};
}
