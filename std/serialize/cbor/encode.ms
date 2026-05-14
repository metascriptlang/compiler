// CBOR encode — macro version of typed encoding.
//
// Two-macro design (mirrors std/serialize/json/encode.ms):
//   cborValueOf(t)  — returns a CborValue for any T (atomic or struct)
//   cborEncode(t)   — wraps encode(cborValueOf(t)) → Buffer
//
// Nested struct support: cborValueOf recurses by emitting `cborValueOf(t.field)`
// for non-atomic field types — the outer macro's return AST contains an inner
// macro call which walkExpand re-expands at the appropriate recursion depth.
//
// Walks t.nodeType (synthesized type-AST per SERIALIZE Phase A1). Refs/Ptrs
// unwrap via TypeGeneric (modifierToAst maps to TypeGeneric with base name).
//
// V1 supported field types — atomic (string, boolean, number, float*, intN,
// uintN, enum, type alias) + nested named struct/interface. Arrays / unions /
// anonymous structs / function fields rejected at expansion. Recursive types
// (`class Node { next: Node }`) hit the Raiser VM instruction budget at
// expansion — V1 doesn't pre-detect cycles.
//
// IMPLEMENTATION NOTE: macros cannot call sibling helper functions defined
// in the same file (Raiser VM constraint, see project_macro_preprocess_walker
// memory). The macro body stays monolithic; AST construction is inlined.

import { Node, NodeKind } from "std/meta";

export macro cborValueOf(t: Node): Node {
	// Resolve underlying type-AST node (peel Ref<Struct> wrapper).
	let tt = t.nodeType;
	if (tt.kind === NodeKind.TypeGeneric) {
		tt = tt.typExprArgs[0];
	}

	// Array field — emit a call to a per-element-type runtime helper.
	// V2 (2026-05-14): atomic-builtin, enum/alias, struct/interface elements.
	// Mirror of std/serialize/json/encode.ms array branch.
	// Builtin elements → per-type fast helpers (cborArrayOfX).
	// Non-builtin Identifier (enum / type alias) → `_cborArrayOfInts<T>` generic.
	// TypeObject element (struct/interface) → `_cborArrayOfStructs<T>` generic.
	if (tt.kind === NodeKind.TypeArray) {
		const elemType: Node = tt.typExprElement;
		let en: string = "";
		let elemIsStruct: boolean = false;
		if (elemType.kind === NodeKind.Identifier) {
			en = elemType.name;
		} else if (elemType.kind === NodeKind.TypeObject) {
			elemIsStruct = true;
			en = elemType.typExprTypeName;
			if (en === "") {
				error("cborValueOf: anonymous struct element arrays unsupported (must name struct via interface/class)", t);
			}
		} else if (elemType.kind === NodeKind.TypeGeneric) {
			// Ref<Struct> wrapper around struct element.
			const peeled: Node = elemType.typExprArgs[0];
			if (peeled.kind === NodeKind.TypeObject) {
				elemIsStruct = true;
				en = peeled.typExprTypeName;
				if (en === "") {
					error("cborValueOf: anonymous struct element arrays unsupported", t);
				}
			} else {
				error("cborValueOf: unsupported array element kind (TypeGeneric inner kind=" + peeled.kind + ")", t);
			}
		} else {
			error("cborValueOf: unsupported array element kind=" + elemType.kind + " (only Identifier or TypeObject supported)", t);
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
					name: "_cborArrayOfStructs",
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
					name: "_cborArrayOfInts",
				},
				arguments: [t],
			};
		}
		// Builtin atomic element → per-element-type fast helper.
		// IF-ELSE not match: macro VM string-match dispatch bug (always picks `_`).
		// See memory project_macro_vm_string_match_bug.
		let helperName: string = "cborArrayOfInt64";
		if (en === "string") helperName = "cborArrayOfStrings";
		else if (en === "boolean") helperName = "cborArrayOfBooleans";
		else if (en === "number") helperName = "cborArrayOfNumbers";
		else if (en === "float64") helperName = "cborArrayOfNumbers";
		else if (en === "float32") helperName = "cborArrayOfFloat32";
		else if (en === "int8") helperName = "cborArrayOfInt8";
		else if (en === "int16") helperName = "cborArrayOfInt16";
		else if (en === "int32") helperName = "cborArrayOfInt32";
		else if (en === "int64") helperName = "cborArrayOfInt64";
		else if (en === "uint8") helperName = "cborArrayOfUint8";
		else if (en === "uint16") helperName = "cborArrayOfUint16";
		else if (en === "uint32") helperName = "cborArrayOfUint32";
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
		// V1 supports atomic types and atomic-element arrays. Unions /
		// Functions land as TypeUnion / TypeFunction kinds (not Identifier).
		if (tt.kind !== NodeKind.Identifier) {
			error("cborValueOf: unsupported field type — only atomic types, atomic arrays, and structs are supported in V1", t);
		}
		const tn: string = tt.name;
		// Pick the CborValue constructor matching the atomic type. Unknown
		// Identifier names (enums, type aliases) fall through to cborInt —
		// enums encode as their underlying int, aliases inherit their target.
		const builderName: string = match (tn) {
			"string" => "cborText",
			"boolean" => "cborBool",
			"number" | "float32" | "float64" => "cborFloat",
			_ => "cborInt",
		};
		// cborInt takes int64 — sized-int / enum / primitive-alias fields need
		// a widening cast. cborFloat takes float64 — float32 widens via cast.
		// cborText/cborBool/cborFloat-with-float64 accept their input directly.
		const castType: string = match (builderName) {
			"cborInt" => "int64",
			"cborFloat" when (tn === "float32") => "float64",
			_ => "",
		};
		const argNode: Node = castType === ""
			? t
			: {
				kind: NodeKind.TypeAssertion,
				line: t.line,
				column: t.column,
				asExpr: t,
				asType: castType,
			};
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

	// Struct type — iterate fields, recurse via cborValueOf(t.field).
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
		// so the recursive cborValueOf macro call can read the field's actual
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
		// Recursive call — walkExpand expands cborValueOf(t.f) per-field
		// based on f's actual type (atomic or struct).
		const recursive: Node = {
			kind: NodeKind.CallExpr,
			line: t.line,
			column: t.column,
			callee: {
				kind: NodeKind.Identifier,
				line: t.line,
				column: t.column,
				name: "cborValueOf",
			},
			arguments: [memberExpr],
		};
		valueNodes.push(recursive);

		// Map keys are text (CBOR allows any-typed keys per RFC 8949 §3.1
		// but text is the standard convention for struct field encoding).
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
			name: "cborTextMap",
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

export macro cborEncode(t: Node): Node {
	// encode(cborValueOf(t))
	return {
		kind: NodeKind.CallExpr,
		line: t.line,
		column: t.column,
		callee: {
			kind: NodeKind.Identifier,
			line: t.line,
			column: t.column,
			name: "encode",
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
					name: "cborValueOf",
				},
				arguments: [t],
			},
		],
	};
}
