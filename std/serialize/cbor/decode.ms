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
import { detectUnionDisc, pickAtomicAccessor } from "../discDetect";

export macro cborValueToStruct(cv: Node, witness: Node): Node {
	let tt = witness.nodeType;
	// Peel `T | null` Union → T (single non-null variant). For multi-variant
	// unions (DU), keep tt as TypeUnion and fall through to the DU branch
	// below. Mirrors JSON decode B-2.3 shape.
	if (tt.kind === NodeKind.TypeUnion) {
		let nonNullCount: int32 = 0;
		let firstNonNull: Node | null = null;
		for (const m of tt.typExprMembers) {
			if (m.kind === NodeKind.Identifier && m.name === "null") continue;
			if (firstNonNull === null) firstNonNull = m;
			nonNullCount = nonNullCount + 1;
		}
		if (nonNullCount === 1 && firstNonNull !== null) {
			tt = firstNonNull;
		}
		// nonNullCount >= 2: leave tt as TypeUnion → DU branch below
	}
	// Peel Ref<Struct> wrapper (interface/class types are reference-typed).
	if (tt.kind === NodeKind.TypeGeneric) {
		tt = tt.typExprArgs[0];
	}

	// V3 — Tagged union (DU) decoding. Mirror JSON decode B-2.3:
	// dispatch on disc field accessor, emit per-variant ObjectLiteral
	// { disc: discLit, ...payload }.
	if (tt.kind === NodeKind.TypeUnion) {
		const info = detectUnionDisc(tt);
		const discField: string = info.discField;
		const discKind: string = info.discKind;
		const variants = info.variants;

		if (discField === "" || variants.length === 0) {
			error("cborValueToStruct: cannot determine discriminator for union type — variants must share a literal-typed disc field", witness);
		}
		if (discKind === "enum") {
			error("cborValueToStruct: enum-discriminated unions not yet supported in decode (encode works); use boolean or string disc", witness);
		}

		// matchDisc: cv.getDynamicField(discField).asBoolean() | .asString()
		const discAccessorName: string = discKind === "boolean" ? "asBoolean" : "asString";
		const matchDisc: Node = {
			kind: NodeKind.CallExpr, line: cv.line, column: cv.column,
			callee: {
				kind: NodeKind.MemberExpr, line: cv.line, column: cv.column,
				object: {
					kind: NodeKind.CallExpr, line: cv.line, column: cv.column,
					callee: { kind: NodeKind.Identifier, line: cv.line, column: cv.column, name: "getDynamicField" },
					arguments: [
						cv,
						{ kind: NodeKind.StringLiteral, line: cv.line, column: cv.column, value: discField },
					],
				},
				property: discAccessorName,
			},
			arguments: [],
		};

		const matchCases: Node[] = [];
		for (const variant of variants) {
			const variantKey: string = variant.key;
			const v: Node = variant.member;
			if (v.kind !== NodeKind.TypeObject) {
				error("cborValueToStruct: union variants must be struct types (got kind=" + v.kind + ")", witness);
			}

			// Pattern + disc literal (mirror encode shape).
			let pattern: Node;
			let discLiteral: Node;
			if (discKind === "boolean") {
				const bv: boolean = variantKey === "true";
				pattern = { kind: NodeKind.BooleanLiteral, line: cv.line, column: cv.column, boolValue: bv };
				discLiteral = { kind: NodeKind.BooleanLiteral, line: cv.line, column: cv.column, boolValue: bv };
			} else {
				pattern = { kind: NodeKind.StringLiteral, line: cv.line, column: cv.column, value: variantKey };
				discLiteral = { kind: NodeKind.StringLiteral, line: cv.line, column: cv.column, value: variantKey };
			}

			// Build per-variant ObjectLiteral: disc field first, then payload.
			const vKeyNodes: string[] = [discField];
			const vValueNodes: Node[] = [discLiteral];
			for (let fi = 0; fi < v.typExprFieldNames.length; fi = fi + 1) {
				const fname: string = v.typExprFieldNames[fi];
				const ftype: Node = v.typExprFieldTypes[fi];
				if (fname === discField) continue;

				if (ftype.kind !== NodeKind.Identifier) {
					error("cborValueToStruct: DU variant payload field '" + fname + "' must be atomic; nested struct + array deferred", witness);
				}
				const a = pickAtomicAccessor(ftype.name);
				const fieldAccess: Node = {
					kind: NodeKind.CallExpr, line: cv.line, column: cv.column,
					callee: {
						kind: NodeKind.MemberExpr, line: cv.line, column: cv.column,
						object: {
							kind: NodeKind.CallExpr, line: cv.line, column: cv.column,
							callee: { kind: NodeKind.Identifier, line: cv.line, column: cv.column, name: "getDynamicField" },
							arguments: [
								cv,
								{ kind: NodeKind.StringLiteral, line: cv.line, column: cv.column, value: fname },
							],
						},
						property: a.methodName,
					},
					arguments: [],
				};
				const finalAccess: Node = a.needsCast
					? { kind: NodeKind.TypeAssertion, line: cv.line, column: cv.column, asExpr: fieldAccess, asType: a.castType }
					: fieldAccess;
				vKeyNodes.push(fname);
				vValueNodes.push(finalAccess);
			}

			matchCases.push({
				kind: NodeKind.MatchCase, line: cv.line, column: cv.column,
				casePatterns: [pattern],
				caseGuard: null as unknown as Node,
				caseBody: {
					kind: NodeKind.ObjectLiteral, line: cv.line, column: cv.column,
					keys: vKeyNodes,
					properties: vValueNodes,
					keyLocations: [],
				},
			});
		}

		return {
			kind: NodeKind.MatchExpr, line: cv.line, column: cv.column,
			matchDisc,
			matchCases,
		};
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

		// Array field — V2: atomic-builtin + enum/alias + struct/interface elements.
		// Builtin → per-type fast helper (cborToXArray).
		// Non-builtin Identifier (enum / type alias) → `_cborToIntArray<T>` generic.
		// Struct/interface → `_cborToStructArray<T>` generic.
		// Bare `null` witness — T binds via Pass 3 contextual return-type
		// binding (Nim parity inheritBindings, semcall.nim:777-859). See
		// bug024 + std/serialize/json/decode.ms array branch for rationale.
		if (ftype.kind === NodeKind.TypeArray) {
			const elemType: Node = ftype.typExprElement;
			let en: string = "";
			let elemIsStruct: boolean = false;
			if (elemType.kind === NodeKind.Identifier) {
				en = elemType.name;
			} else if (elemType.kind === NodeKind.TypeObject) {
				elemIsStruct = true;
				en = elemType.typExprTypeName;
				if (en === "") {
					error("cborValueToStruct: anonymous struct element arrays unsupported (field '" + fname + "')", witness);
				}
			} else if (elemType.kind === NodeKind.TypeGeneric) {
				const peeled: Node = elemType.typExprArgs[0];
				if (peeled.kind === NodeKind.TypeObject) {
					elemIsStruct = true;
					en = peeled.typExprTypeName;
					if (en === "") {
						error("cborValueToStruct: anonymous struct element arrays unsupported (field '" + fname + "')", witness);
					}
				} else {
					error("cborValueToStruct: unsupported array element kind=TypeGeneric (field '" + fname + "')", witness);
				}
			} else {
				error("cborValueToStruct: unsupported array element kind=" + elemType.kind + " (field '" + fname + "')", witness);
			}
			const isBuiltin: boolean = en === "string" || en === "boolean"
				|| en === "number" || en === "float32" || en === "float64"
				|| en === "int8" || en === "int16" || en === "int32" || en === "int64"
				|| en === "uint8" || en === "uint16" || en === "uint32";

			// Generic-helper path: enum/alias → _cborToIntArray<T>;
			// struct/interface → _cborToStructArray<T>. Witness is bare
			// `null` — Pass 3 contextual binding + post-mono reconciliation
			// (bug024) bind T from caller-side `: Color[]` / `: Item[]` ctx.
			if (elemIsStruct || !isBuiltin) {
				const getCall: Node = {
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
				};
				const witnessNode: Node = {
					kind: NodeKind.NullLiteral,
					line: cv.line,
					column: cv.column,
					nullPlaceholder: true,
				};
				const helperName: string = elemIsStruct ? "_cborToStructArray" : "_cborToIntArray";
				const arrCall: Node = {
					kind: NodeKind.CallExpr,
					line: cv.line,
					column: cv.column,
					callee: {
						kind: NodeKind.Identifier,
						line: cv.line,
						column: cv.column,
						name: helperName,
					},
					arguments: [getCall, witnessNode],
				};
				keyNodes.push(fname);
				valueNodes.push(arrCall);
				i = i + 1;
				continue;
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

		// Literal-typed field (e.g. `kind: "circle"`, `ok: true`). Bridge
		// emits StringLiteral/BooleanLiteral nodes for these. Decoded value
		// MUST equal the literal — emit the literal directly, ignore cv.
		// Mirrors JSON decode Bug A fix.
		if (ftype.kind === NodeKind.StringLiteral) {
			keyNodes.push(fname);
			valueNodes.push(ftype);
			i = i + 1;
			continue;
		}
		if (ftype.kind === NodeKind.BooleanLiteral) {
			keyNodes.push(fname);
			valueNodes.push({ kind: NodeKind.BooleanLiteral, line: cv.line, column: cv.column, boolValue: ftype.boolValue });
			i = i + 1;
			continue;
		}
		// Atomic field — Identifier with `.name` from mapTypeToAst's
		// atomicTypeName. Anything else is rejected.
		if (ftype.kind !== NodeKind.Identifier) {
			error("cborValueToStruct: union fields not supported in V1; field '" + fname + "'", witness);
		}
		const a = pickAtomicAccessor(ftype.name);
		// getDynamicField(cv, "fname").<accessor>() — MemberExpr-callee style
		// so the extension dispatcher resolves the accessor.
		const fieldAccess: Node = {
			kind: NodeKind.CallExpr, line: cv.line, column: cv.column,
			callee: {
				kind: NodeKind.MemberExpr, line: cv.line, column: cv.column,
				object: {
					kind: NodeKind.CallExpr, line: cv.line, column: cv.column,
					callee: { kind: NodeKind.Identifier, line: cv.line, column: cv.column, name: "getDynamicField" },
					arguments: [
						cv,
						{ kind: NodeKind.StringLiteral, line: cv.line, column: cv.column, value: fname },
					],
				},
				property: a.methodName,
			},
			arguments: [],
		};
		const finalAccess: Node = a.needsCast
			? { kind: NodeKind.TypeAssertion, line: cv.line, column: cv.column, asExpr: fieldAccess, asType: a.castType }
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
