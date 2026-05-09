// JSON encode — macro version of JSON.stringify
//
// Two-macro design:
//   jsonValueOf(t)  — returns a JsonValue for any T (atomic or struct)
//   jsonStringify(t) — wraps stringify(jsonValueOf(t), false)
//
// Nested struct support: jsonValueOf recurses by emitting `jsonValueOf(t.field)`
// for non-atomic field types — the outer macro's return AST contains an inner
// macro call which walkExpand re-expands at the appropriate recursion depth.
//
// Walks t.nodeType (synthesized type-AST per SERIALIZE Phase A1). Refs/Ptrs
// unwrap via TypeGeneric (modifierToAst maps to TypeGeneric with base name).
import { Node, NodeKind } from "std/meta";

export macro jsonValueOf(t: Node): Node {
	// Resolve underlying type-AST node (peel Ref<Struct> wrapper).
	let tt = t.nodeType;
	if (tt.kind === NodeKind.TypeGeneric) {
		tt = tt.typExprArgs[0];
	}

	// Array field — emit a call to a per-element-type runtime helper that
	// builds JsonValue[] then wraps in jsonArray. Atomic-element arrays only
	// in V1.5 (string[], boolean[], number[], int*[], uint*[], float*[]).
	// Struct-element arrays (`Person[]`) deferred to V2 (need multi-decl
	// macro emission to define per-T wrapper that calls jsonValueOf inline).
	if (tt.kind === NodeKind.TypeArray) {
		const elemType: Node = tt.typExprElement;
		if (elemType.kind !== NodeKind.Identifier) {
			error("jsonValueOf: V1.5 array fields support atomic-element types only (string/boolean/number/intN/uintN/floatN); struct-element arrays deferred to V2 (got element kind=" + elemType.kind + ")", t);
		}
		const en: string = elemType.name;
		// Per-sized-int / per-float-precision dispatch — array-level cast
		// would reinterpret bytes wrong (different element strides). Each
		// helper widens per-element internally.
		// IF-ELSE not match: macro VM has a string-match dispatch bug (always
		// picks `_` arm). See memory project_macro_vm_string_match_bug.
		let helperName: string = "jsonArrayOfInt64";   // default for enum/alias
		if (en === "string") helperName = "jsonArrayOfStrings";
		else if (en === "boolean") helperName = "jsonArrayOfBooleans";
		else if (en === "number") helperName = "jsonArrayOfNumbers";
		else if (en === "float64") helperName = "jsonArrayOfNumbers";
		else if (en === "float32") helperName = "jsonArrayOfFloat32";
		else if (en === "int8") helperName = "jsonArrayOfInt8";
		else if (en === "int16") helperName = "jsonArrayOfInt16";
		else if (en === "int32") helperName = "jsonArrayOfInt32";
		else if (en === "int64") helperName = "jsonArrayOfInt64";
		else if (en === "uint8") helperName = "jsonArrayOfUint8";
		else if (en === "uint16") helperName = "jsonArrayOfUint16";
		else if (en === "uint32") helperName = "jsonArrayOfUint32";
		return {
			kind: NodeKind.CallExpr,
			line: t.line,
			column: t.column,
			callee: {
				kind: NodeKind.Identifier,
				line: t.line,
				column: t.column,
				name: helperName,
			},
			arguments: [t],
		};
	}

	// Non-struct (atomic) types — emit a direct builder call on `t`.
	if (tt.kind !== NodeKind.TypeObject) {
		// V1 supports atomic types and arrays-of-atomic. Unions / Functions
		// land as TypeUnion / TypeFunction kinds (not Identifier) → reject.
		if (tt.kind !== NodeKind.Identifier) {
			error("jsonValueOf: unsupported field type — only atomic types, atomic arrays, and structs are supported in V1", t);
		}
		const tn: string = tt.name;
		// Unknown Identifier names fall through to jsonInt — mirrors @builtin's
		// classifyJsonPrimitive treating Enum as int. Primitive aliases (e.g.,
		// `type UserId = int32`) encode as int via the alias chain.
		const builderName: string = match (tn) {
			"string" => "jsonString",
			"boolean" => "jsonBool",
			"number" | "float32" | "float64" => "jsonNumber",
			_ => "jsonInt",
		};
		// jsonInt takes int64 — sized-int / enum / primitive-alias fields
		// need a widening cast so the call type-checks. jsonString/jsonBool/
		// jsonNumber accept their input directly.
		const argNode: Node = builderName === "jsonInt"
			? {
				kind: NodeKind.TypeAssertion,
				line: t.line,
				column: t.column,
				asExpr: t,
				asType: "int64",
			}
			: t;
		return {
			kind: NodeKind.CallExpr,
			line: t.line,
			column: t.column,
			callee: {
				kind: NodeKind.Identifier,
				line: t.line,
				column: t.column,
				name: builderName,
			},
			arguments: [argNode],
		};
	}

	// Struct type — iterate fields, recurse via jsonValueOf(t.field).
	const fields: string[] = tt.typExprFieldNames;
	const fieldTypes: Node[] = tt.typExprFieldTypes;
	const valueNodes: Node[] = [];
	const keyNodes: Node[] = [];
	let fi = 0;
	while (fi < fields.length) {
		const f: string = fields[fi];
		const ft: Node = fieldTypes[fi];
		// Emit MemberExpr with nodeType set to the field's type-AST. This
		// propagates type info through valueToNode's nodeTypeAst preservation
		// so the recursive jsonValueOf macro call can read the field's actual
		// type at expansion time. Without this, the recursive macro sees a
		// nodeType-less MemberExpr and errors "unsupported field type".
		const memberExpr: Node = {
			kind: NodeKind.MemberExpr,
			line: t.line,
			column: t.column,
			object: t,
			property: f,
			nodeType: ft,
		};
		// Recursive call — walkExpand will expand jsonValueOf(t.f) per-field
		// based on f's actual type (atomic or struct).
		const recursive: Node = {
			kind: NodeKind.CallExpr,
			line: t.line,
			column: t.column,
			callee: {
				kind: NodeKind.Identifier,
				line: t.line,
				column: t.column,
				name: "jsonValueOf",
			},
			arguments: [memberExpr],
		};
		valueNodes.push(recursive);

		const keyLit: Node = {
			kind: NodeKind.StringLiteral,
			line: t.line,
			column: t.column,
			value: f,
		};
		keyNodes.push(keyLit);
		fi = fi + 1;
	}

	return {
		kind: NodeKind.CallExpr,
		line: t.line,
		column: t.column,
		callee: {
			kind: NodeKind.Identifier,
			line: t.line,
			column: t.column,
			name: "jsonObject",
		},
		arguments: [
			{
				kind: NodeKind.ArrayLiteral,
				line: t.line,
				column: t.column,
				elements: keyNodes,
			},
			{
				kind: NodeKind.ArrayLiteral,
				line: t.line,
				column: t.column,
				elements: valueNodes,
			},
		],
	};
}

export macro jsonStringify(t: Node): Node {
	// stringify(jsonValueOf(t), false)
	return {
		kind: NodeKind.CallExpr,
		line: t.line,
		column: t.column,
		callee: {
			kind: NodeKind.Identifier,
			line: t.line,
			column: t.column,
			name: "stringify",
		},
		arguments: [
			{
				kind: NodeKind.CallExpr,
				line: t.line,
				column: t.column,
				callee: {
					kind: NodeKind.Identifier,
					line: t.line,
					column: t.column,
					name: "jsonValueOf",
				},
				arguments: [t],
			},
			{
				kind: NodeKind.BooleanLiteral,
				line: t.line,
				column: t.column,
				boolValue: false,
			},
		],
	};
}
