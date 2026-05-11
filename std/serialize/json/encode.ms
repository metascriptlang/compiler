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

	// Array field — emit a call to a per-element-type runtime helper.
	// V2 (2026-05-10): atomic-builtin, enum/alias, struct/interface elements.
	// Builtin elements → per-type fast helpers (jsonArrayOfX).
	// Non-builtin Identifier (enum / type alias) → `_jsonArrayOfInts<T>` generic.
	// TypeObject element (struct/interface) → `_jsonArrayOfStructs<T>` generic.
	// IIFE-closure / function / union element types remain rejected.
	if (tt.kind === NodeKind.TypeArray) {
		const elemType: Node = tt.typExprElement;
		// Identifier element name — empty if elem is TypeObject (struct).
		let en: string = "";
		let elemIsStruct: boolean = false;
		if (elemType.kind === NodeKind.Identifier) {
			en = elemType.name;
		} else if (elemType.kind === NodeKind.TypeObject) {
			elemIsStruct = true;
			en = elemType.typExprTypeName;
			if (en === "") {
				error("jsonValueOf: anonymous struct element arrays unsupported (must name struct via interface/class)", t);
			}
		} else if (elemType.kind === NodeKind.TypeGeneric) {
			// Ref<Struct> wrapper around struct element
			const peeled: Node = elemType.typExprArgs[0];
			if (peeled.kind === NodeKind.TypeObject) {
				elemIsStruct = true;
				en = peeled.typExprTypeName;
				if (en === "") {
					error("jsonValueOf: anonymous struct element arrays unsupported", t);
				}
			} else {
				error("jsonValueOf: unsupported array element kind (TypeGeneric inner kind=" + peeled.kind + ")", t);
			}
		} else {
			error("jsonValueOf: unsupported array element kind=" + elemType.kind + " (only Identifier or TypeObject supported)", t);
		}
		const isBuiltin: boolean = en === "string" || en === "boolean"
			|| en === "number" || en === "float32" || en === "float64"
			|| en === "int8" || en === "int16" || en === "int32" || en === "int64"
			|| en === "uint8" || en === "uint16" || en === "uint32";

		// Struct/interface element → generic struct helper (recursive macro re-expansion at mono-time).
		if (elemIsStruct) {
			return {
				kind: NodeKind.CallExpr,
				line: t.line,
				column: t.column,
				callee: {
					kind: NodeKind.Identifier,
					line: t.line,
					column: t.column,
					name: "_jsonArrayOfStructs",
				},
				arguments: [t],
			};
		}
		// Non-builtin Identifier (enum / type alias) → generic int helper.
		if (!isBuiltin) {
			return {
				kind: NodeKind.CallExpr,
				line: t.line,
				column: t.column,
				callee: {
					kind: NodeKind.Identifier,
					line: t.line,
					column: t.column,
					name: "_jsonArrayOfInts",
				},
				arguments: [t],
			};
		}
		// Builtin atomic element → per-element-type fast helper.
		// IF-ELSE not match: macro VM string-match dispatch bug (always
		// picks `_` arm). See memory project_macro_vm_string_match_bug.
		let helperName: string = "jsonArrayOfInt64";
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
