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
import { detectUnionDisc, parseDiscKey } from "../discDetect";

export macro jsonValueOf(t: Node): Node {
	// Resolve underlying type-AST node (peel Ref<Struct> wrapper).
	let tt = t.nodeType;
	if (tt.kind === NodeKind.TypeGeneric) {
		tt = tt.typExprArgs[0];
	}

	// Array field — emit a call to a per-element-type runtime helper.
	// V2: atomic-builtin, enum/alias, struct/interface elements.
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
		// IF-ELSE not match: macro VM string-match dispatch always picks `_`.
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

	// V3 — Tagged-union (discriminated union) field. Emit runtime match on
	// the disc field that dispatches to per-variant jsonObject construction.
	// Step 2: bridge-populated path only (match-type DUs + Result/Option peeled).
	// TS-style auto-detect deferred to step 4.
	//
	// Per-variant code structure:
	//   <pattern> => jsonObject(["disc", payload-keys...], [discValueLit, jsonValueOf(t.field)...])
	//
	// Pattern type by discKind:
	//   "boolean" → BooleanLiteral pattern, jsonBool disc value
	//   "enum"    → MemberExpr(EnumName, MemberName) pattern, jsonString member name
	//   default   → StringLiteral pattern, jsonString variantKey value
	if (tt.kind === NodeKind.TypeUnion) {
		// V3 — Tagged union (DU) encoding. Auto-detect disc info via shared
		// helper (combines bridge-populated fields + TS-style fallback).
		// info.variants pairs each disc key with its peeled variant struct
		// — no parallel-list indexing fragility.
		const info = detectUnionDisc(tt);
		const discField: string = info.discField;
		const discKind: string = info.discKind;
		const variants = info.variants;

		if (discField === "" || variants.length === 0) {
			error("jsonValueOf: cannot determine discriminator for union type — variants must share a literal-typed disc field", t);
		}

		const matchCases: Node[] = [];
		for (const variant of variants) {
			const variantKey: string = variant.key;
			const v: Node = variant.member;
			if (v.kind !== NodeKind.TypeObject) {
				error("jsonValueOf: union variants must be struct types (got kind=" + v.kind + ")", t);
			}

			// Build pattern + disc value Node based on discKind.
			// parseDiscKey splits "K.A" enum keys into enumName + memberName.
			const dp = parseDiscKey(discKind, variantKey);
			let pattern: Node;
			let discValueNode: Node;
			if (discKind === "boolean") {
				pattern = { kind: NodeKind.BooleanLiteral, line: t.line, column: t.column, boolValue: dp.boolValue };
				discValueNode = {
					kind: NodeKind.CallExpr, line: t.line, column: t.column,
					callee: { kind: NodeKind.Identifier, line: t.line, column: t.column, name: "jsonBool" },
					arguments: [{ kind: NodeKind.BooleanLiteral, line: t.line, column: t.column, boolValue: dp.boolValue }],
				};
			} else if (discKind === "enum") {
				pattern = {
					kind: NodeKind.MemberExpr, line: t.line, column: t.column,
					object: { kind: NodeKind.Identifier, line: t.line, column: t.column, name: dp.enumName },
					property: dp.memberName,
					isOptional: false,
				};
				discValueNode = {
					kind: NodeKind.CallExpr, line: t.line, column: t.column,
					callee: { kind: NodeKind.Identifier, line: t.line, column: t.column, name: "jsonString" },
					arguments: [{ kind: NodeKind.StringLiteral, line: t.line, column: t.column, value: dp.memberName }],
				};
			} else {
				// String disc (TS-style) — pattern + value both StringLiteral.
				pattern = { kind: NodeKind.StringLiteral, line: t.line, column: t.column, value: variantKey };
				discValueNode = {
					kind: NodeKind.CallExpr, line: t.line, column: t.column,
					callee: { kind: NodeKind.Identifier, line: t.line, column: t.column, name: "jsonString" },
					arguments: [{ kind: NodeKind.StringLiteral, line: t.line, column: t.column, value: variantKey }],
				};
			}

			// Build key/value arrays for jsonObject — disc first, then payload.
			const vKeyNodes: Node[] = [{ kind: NodeKind.StringLiteral, line: t.line, column: t.column, value: discField }];
			const vValueNodes: Node[] = [discValueNode];
			let fi = 0;
			while (fi < v.typExprFieldNames.length) {
				const fname: string = v.typExprFieldNames[fi];
				const ft: Node = v.typExprFieldTypes[fi];
				if (fname !== discField) {
					vKeyNodes.push({ kind: NodeKind.StringLiteral, line: t.line, column: t.column, value: fname });
					const memberExpr: Node = {
						kind: NodeKind.MemberExpr, line: t.line, column: t.column,
						object: t, property: fname, nodeType: ft, isOptional: false,
					};
					vValueNodes.push({
						kind: NodeKind.CallExpr, line: t.line, column: t.column,
						callee: { kind: NodeKind.Identifier, line: t.line, column: t.column, name: "jsonValueOf" },
						arguments: [memberExpr],
					});
				}
				fi = fi + 1;
			}

			// Build match case in 1 expression — avoid `let pattern` capture-by-ref bug
			// (MS macro VM appears to share let-var refs across loop iterations,
			// causing all matchCases to see the LAST iteration's pattern).
			matchCases.push({
				kind: NodeKind.MatchCase, line: t.line, column: t.column,
				casePatterns: [pattern],
				caseGuard: null as unknown as Node,
				caseBody: {
					kind: NodeKind.CallExpr, line: t.line, column: t.column,
					callee: { kind: NodeKind.Identifier, line: t.line, column: t.column, name: "jsonObject" },
					arguments: [
						{ kind: NodeKind.ArrayLiteral, line: t.line, column: t.column, elements: vKeyNodes },
						{ kind: NodeKind.ArrayLiteral, line: t.line, column: t.column, elements: vValueNodes },
					],
				},
			});
		}

		return {
			kind: NodeKind.MatchExpr, line: t.line, column: t.column,
			matchDisc: {
				kind: NodeKind.MemberExpr, line: t.line, column: t.column,
				object: t, property: discField, isOptional: false,
			},
			matchCases,
		};
	}

	// Non-struct (atomic) types — emit a direct builder call on `t`.
	if (tt.kind !== NodeKind.TypeObject) {
		// Literal-typed field (TS-style DU disc, e.g. `kind: "circle"`).
		// Bridge emits StringLiteral/BooleanLiteral nodes for these — the
		// runtime field value is just a regular string/bool, so route to
		// jsonString/jsonBool. Without this branch they fell through to the
		// Identifier path below, got tn="circle", missed the atomic match,
		// and landed in jsonInt with a bad msString-as-int64 cast.
		const literalBuilder: string = match (tt.kind) {
			NodeKind.StringLiteral => "jsonString",
			NodeKind.BooleanLiteral => "jsonBool",
			_ => "",
		};
		if (literalBuilder !== "") {
			return {
				kind: NodeKind.CallExpr, line: t.line, column: t.column,
				callee: { kind: NodeKind.Identifier, line: t.line, column: t.column, name: literalBuilder },
				arguments: [t],
			};
		}
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
