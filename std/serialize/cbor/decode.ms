// CBOR decode — macro version of typed CBOR parsing.
//
// Two-piece design (mirrors std/serialize/json/decode.ms):
//   cborValueToStruct(cv, witness)  — macro: emits inline struct construction
//                                      `{ field: getDynamicField(cv, "field").<accessor>, ... }`
//   parseAs<T>(input)               — generic function: parses + checks Result + wraps
//
// Witness pattern: caller passes `null as T | null`. Macro peels the union
// to extract T, then emits an ObjectLiteral constructing T from per-field
// accessor calls on getDynamicField(cv, "field").
//
// V1 supported field types — atomic + nested named struct/interface. Arrays /
// unions / anonymous structs / function fields rejected at expansion. Recursive
// types hit the Raiser VM instruction budget at expansion (V1 doesn't pre-
// detect cycles).
//
// IMPLEMENTATION NOTE: macros cannot call sibling helper functions defined
// in the same file (Raiser VM constraint, see project_macro_preprocess_walker
// memory). The macro body stays monolithic; AST construction is inlined.

import { Node, NodeKind } from "std/meta";

export macro cborValueToStruct(cv: Node, witness: Node): Node {
	let tt = witness.nodeType;
	// Peel `T | null` Union → T. mapTypeToAst produces TypeUnion with
	// typExprMembers; the null variant lands as Identifier("null").
	if (tt.kind === NodeKind.TypeUnion) {
		for (const m of tt.typExprMembers) {
			if (m.kind === NodeKind.Identifier && m.name === "null") continue;
			tt = m;
			break;
		}
	}
	// Peel Ref<Struct> wrapper (interface/class types are reference-typed).
	if (tt.kind === NodeKind.TypeGeneric) {
		tt = tt.typExprArgs[0];
	}
	if (tt.kind !== NodeKind.TypeObject) {
		error("cborValueToStruct: target type must be a struct/interface; atomic types not supported", witness);
	}

	const fields: string[] = tt.typExprFieldNames;
	const fieldTypes: Node[] = tt.typExprFieldTypes;
	const keyNodes: string[] = [];
	const valueNodes: Node[] = [];
	let i = 0;
	while (i < fields.length) {
		const fname: string = fields[i];
		const ftype: Node = fieldTypes[i];

		// Nested struct field: peel Ref<Struct> → TypeObject, then emit a
		// recursive cborValueToStruct call with a typed witness `null as
		// <Inner> | null`. Inner type name comes from TypeObjectData
		// .typExprTypeName, populated by mapTypeToAst's structToAst.
		let innerStruct: Node | null = null;
		if (ftype.kind === NodeKind.TypeGeneric) {
			const peeled = ftype.typExprArgs[0];
			if (peeled.kind === NodeKind.TypeObject) innerStruct = peeled;
		} else if (ftype.kind === NodeKind.TypeObject) {
			innerStruct = ftype;
		}
		if (innerStruct !== null) {
			const innerName: string = innerStruct.typExprTypeName;
			if (innerName === "") {
				error("cborValueToStruct: anonymous nested struct fields unsupported (field '" + fname + "'); name the inner struct via interface/class", witness);
			}
			// cborValueToStruct(getDynamicField(cv, "f"), null as Inner | null)
			const recursiveCall: Node = {
				kind: NodeKind.CallExpr,
				line: cv.line,
				column: cv.column,
				callee: {
					kind: NodeKind.Identifier,
					line: cv.line,
					column: cv.column,
					name: "cborValueToStruct",
				},
				arguments: [
					{
						kind: NodeKind.CallExpr,
						line: cv.line,
						column: cv.column,
						callee: {
							kind: NodeKind.Identifier,
							line: cv.line,
							column: cv.column,
							name: "getDynamicField",
						},
						arguments: [
							cv,
							{
								kind: NodeKind.StringLiteral,
								line: cv.line,
								column: cv.column,
								value: fname,
							},
						],
					},
					{
						kind: NodeKind.TypeAssertion,
						line: cv.line,
						column: cv.column,
						asExpr: {
							kind: NodeKind.NullLiteral,
							line: cv.line,
							column: cv.column,
							nullPlaceholder: true,
						},
						asType: innerName + " | null",
					},
				],
			};
			keyNodes.push(fname);
			valueNodes.push(recursiveCall);
			i = i + 1;
			continue;
		}

		// Array field — emit `cborToXArray(getDynamicField(cv, "f"))`.
		// V1.5: atomic-element arrays only; struct-element arrays deferred V2.
		if (ftype.kind === NodeKind.TypeArray) {
			const elemType: Node = ftype.typExprElement;
			if (elemType.kind !== NodeKind.Identifier) {
				error("cborValueToStruct: V1.5 array fields support atomic-element types only; struct-element arrays deferred to V2 (field '" + fname + "')", witness);
			}
			const en: string = elemType.name;
			// Reject non-builtin element types — fall-through emits the wrong
			// array type. See std/serialize/json/encode.ms for rationale.
			const isBuiltin: boolean = en === "string" || en === "boolean"
				|| en === "number" || en === "float32" || en === "float64"
				|| en === "int8" || en === "int16" || en === "int32" || en === "int64"
				|| en === "uint8" || en === "uint16" || en === "uint32";
			if (!isBuiltin) {
				error("cborValueToStruct: V1.5 array fields support builtin atomic element types only; enum/alias/struct element arrays deferred to V2 (field '" + fname + "', element type '" + en + "')", witness);
			}
			// IF-ELSE not match (Raiser VM string-match bug, see memory).
			let arrHelper: string = "cborToInt64Array";
			if (en === "string") arrHelper = "cborToStringArray";
			else if (en === "boolean") arrHelper = "cborToBooleanArray";
			else if (en === "number") arrHelper = "cborToNumberArray";
			else if (en === "float64") arrHelper = "cborToNumberArray";
			else if (en === "float32") arrHelper = "cborToFloat32Array";
			else if (en === "int8") arrHelper = "cborToInt8Array";
			else if (en === "int16") arrHelper = "cborToInt16Array";
			else if (en === "int32") arrHelper = "cborToInt32Array";
			else if (en === "int64") arrHelper = "cborToInt64Array";
			else if (en === "uint8") arrHelper = "cborToUint8Array";
			else if (en === "uint16") arrHelper = "cborToUint16Array";
			else if (en === "uint32") arrHelper = "cborToUint32Array";
			// Identifier-callee form: `arrHelper(getDynamicField(cv, "f"))`.
			// Extension-dispatch via MemberExpr fails to resolve in the
			// monomorphized macro-expansion scope (Bug 53 family); positional
			// call resolves directly via the symbol table.
			const arrFieldAccess: Node = {
				kind: NodeKind.CallExpr,
				line: cv.line,
				column: cv.column,
				callee: {
					kind: NodeKind.Identifier,
					line: cv.line,
					column: cv.column,
					name: arrHelper,
				},
				arguments: [
					{
						kind: NodeKind.CallExpr,
						line: cv.line,
						column: cv.column,
						callee: {
							kind: NodeKind.Identifier,
							line: cv.line,
							column: cv.column,
							name: "getDynamicField",
						},
						arguments: [
							cv,
							{
								kind: NodeKind.StringLiteral,
								line: cv.line,
								column: cv.column,
								value: fname,
							},
						],
					},
				],
			};
			keyNodes.push(fname);
			valueNodes.push(arrFieldAccess);
			i = i + 1;
			continue;
		}

		// Atomic field — Identifier with `.name` from mapTypeToAst's
		// atomicTypeName. Anything else is rejected.
		if (ftype.kind !== NodeKind.Identifier) {
			error("cborValueToStruct: union fields not supported in V1; field '" + fname + "'", witness);
		}
		const tn: string = ftype.name;

		// Pick the bridge accessor for this atomic type. Same dispatch logic
		// as JSON — sized-int / enum / int-aliased fields go through asInt64
		// + TypeAssertion to narrow int64 → declared field type.
		const accessorName: string = match (tn) {
			"string" => "asString",
			"boolean" => "asBoolean",
			"number" | "float32" | "float64" => "asNumber",
			_ => "asInt64",   // sized int / uint / enum / int-aliased
		};

		// Only emit explicit TypeAssertion for builtin-named narrowing.
		// User-defined names (enums, type aliases) skip the cast — the
		// surrounding ObjectLiteral assignment context-types each property
		// and fitNode inserts HiddenStdConv (range-check / implicit cast)
		// for the int64→<field> narrowing. A TypeAssertion-by-name fails
		// to resolve when the macro expands inside a generic helper's
		// monomorphized body whose scope doesn't include user-defined
		// types — same gap documented in std/serialize/json/decode.ms.
		const isBuiltinNarrowName: boolean = match (tn) {
			"int8" | "int16" | "int32" | "int64"
				| "uint8" | "uint16" | "uint32" | "uint64"
				| "float32" => true,
			_ => false,
		};
		const needsCast: boolean = match (tn) {
			"string" | "boolean" | "number" | "float64" => false,
			_ => isBuiltinNarrowName,
		};

		// getDynamicField(cv, "fname").<accessorName>()
		// MemberExpr-callee style so the extension dispatcher resolves the
		// accessor; Identifier-callee style fails because extensions are only
		// reachable via member-call form.
		const fieldAccess: Node = {
			kind: NodeKind.CallExpr,
			line: cv.line,
			column: cv.column,
			callee: {
				kind: NodeKind.MemberExpr,
				line: cv.line,
				column: cv.column,
				object: {
					kind: NodeKind.CallExpr,
					line: cv.line,
					column: cv.column,
					callee: {
						kind: NodeKind.Identifier,
						line: cv.line,
						column: cv.column,
						name: "getDynamicField",
					},
					arguments: [
						cv,
						{
							kind: NodeKind.StringLiteral,
							line: cv.line,
							column: cv.column,
							value: fname,
						},
					],
				},
				property: accessorName,
			},
			arguments: [],
		};

		// Cast narrows the bridge accessor's wide return (int64 / number) down
		// to the declared field type — int32, float32, Color enum, alias, etc.
		const finalAccess: Node = needsCast
			? {
				kind: NodeKind.TypeAssertion,
				line: cv.line,
				column: cv.column,
				asExpr: fieldAccess,
				asType: tn,
			}
			: fieldAccess;

		keyNodes.push(fname);
		valueNodes.push(finalAccess);
		i = i + 1;
	}

	return {
		kind: NodeKind.ObjectLiteral,
		line: cv.line,
		column: cv.column,
		keys: keyNodes,
		properties: valueNodes,
		keyLocations: [],
	};
}
