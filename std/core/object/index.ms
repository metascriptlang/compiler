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

import { Node, NodeKind } from "std/meta";

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

export macro objectKeysOf(t: Node): Node {
	// Peel Ref<Struct> (TypeGeneric) to the shape node — same peel the JSON
	// encoder applies before reading typExprFieldNames. Macro bodies are not
	// deeply type-checked, which is what allows walking the type-AST fields.
	let tt = t.nodeType;
	if (tt.kind == NodeKind.TypeGeneric) {
		tt = tt.typExprArgs[0];
	}
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
	let tt = t.nodeType;
	if (tt.kind == NodeKind.TypeGeneric) {
		tt = tt.typExprArgs[0];
	}
	if (tt.kind != NodeKind.TypeObject) {
		error("Object.values: expected an object type (interface/struct/class) — primitives and arrays have no field shape", t);
	}
	const fields = tt.typExprFieldNames;
	const types = tt.typExprFieldTypes;
	const vals: Node[] = [];
	let uniform: string = "";
	let mixed = false;
	let i = 0;
	while (i < fields.length) {
		if (types[i].kind != NodeKind.Identifier) {
			mixed = true;
		} else if (uniform == "") {
			uniform = types[i].name;
		} else if (uniform != types[i].name) {
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
