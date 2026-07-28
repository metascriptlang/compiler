// JSON decode — macro version of typed JSON parsing.
//
// Two-piece design:
//   jsonValueToStruct(jv, witness) — macro: emits inline struct construction
//                                     `{ field: getDynamicField(jv, "field").<accessor>, ... }`
//   parseAs<T>(input)              — generic function: parses + checks Result + wraps
//
// IIFE was the original plan but that path tripped over a chain of compiler
// bugs (see docs/IIFE-BUGS.md). The two-piece design avoids inline IIFE — the
// macro only emits a single ObjectLiteral expression, control flow lives in
// the regular function which MS handles correctly out of the box.
//
// Day 5 scope: all atomic field types (string/boolean/number/float*/int*/uint*).
// Nested struct fields deferred until typeName is surfaced on TypeObjectData
// (needed to construct the inner-type witness for recursive macro call).
import { Node, NodeKind } from "std/meta";
import { detectUnionDisc, pickAtomicAccessor } from "../discDetect";

// Macro: jv must be a JsonValue. Witness expression must be typed `T | null`
// (e.g., user passes `null as Person | null`). Honest nullable typing — null
// is a real member of T | null, not a deceptive `null as unknown as T` lie.
// The macro peels the Union to extract T, then emits an ObjectLiteral
// constructing T from per-field accessor calls.
export macro jsonValueToStruct(jv: Node, witness: Node): Node {
	let tt = witness.nodeType;
	// Peel `T | null` Union → T (single non-null variant). For multi-variant
	// unions (DU), keep tt as TypeUnion and fall through to the DU branch
	// below. Pre-V3 code peeled to first non-null variant unconditionally —
	// that silently dropped variant 2+ for `A | B | null` cases.
	if (tt.kind === NodeKind.TypeUnion) {
		let nonNullCount: int32 = 0;
		let firstNonNull: Node = null as unknown as Node;
		for (const m of tt.typExprMembers) {
			if (m.kind === NodeKind.Identifier && m.name === "null") continue;
			if (firstNonNull === null) firstNonNull = m;
			nonNullCount = nonNullCount + 1;
		}
		if (nonNullCount === 1) {
			tt = firstNonNull;
		}
		// nonNullCount >= 2: leave tt as TypeUnion → DU branch below
	}
	// Peel Ref<Struct> wrapper (interface/class types are reference-typed).
	if (tt.kind === NodeKind.TypeGeneric) {
		tt = tt.typExprArgs[0];
	}

	// V3 — Tagged union (DU) decoding. Mirror encode shape: dispatch on disc
	// field accessor, emit per-variant ObjectLiteral { disc: discLit, ...payload }.
	// Supports boolean + string disc (enum disc deferred — needs name→enum
	// mapping). Variant payload restricted to atomic fields (string/bool/
	// number/int*/float*) — nested struct + array in variant deferred.
	if (tt.kind === NodeKind.TypeUnion) {
		const info = detectUnionDisc(tt);
		const discField: string = info.discField;
		const discKind: string = info.discKind;
		const variants = info.variants;

		if (discField === "" || variants.length === 0) {
			error("jsonValueToStruct: cannot determine discriminator for union type — variants must share a literal-typed disc field", witness);
		}
		if (discKind === "enum") {
			error("jsonValueToStruct: enum-discriminated unions not yet supported in decode (encode works); use boolean or string disc", witness);
		}

		// matchDisc: jv.getDynamicField(discField).asBoolean() | .asString()
		const discAccessorName: string = discKind === "boolean" ? "asBoolean" : "asString";
		const matchDisc: Node = {
			kind: NodeKind.CallExpr, line: jv.line, column: jv.column,
			callee: {
				kind: NodeKind.MemberExpr, line: jv.line, column: jv.column,
				object: {
					kind: NodeKind.CallExpr, line: jv.line, column: jv.column,
					callee: { kind: NodeKind.Identifier, line: jv.line, column: jv.column, name: "getDynamicField" },
					arguments: [
						jv,
						{ kind: NodeKind.StringLiteral, line: jv.line, column: jv.column, value: discField },
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
				error("jsonValueToStruct: union variants must be struct types (got kind=" + v.kind + ")", witness);
			}

			// Pattern + disc literal (mirror encode shape).
			let pattern: Node;
			let discLiteral: Node;
			if (discKind === "boolean") {
				const bv: boolean = variantKey === "true";
				pattern = { kind: NodeKind.BooleanLiteral, line: jv.line, column: jv.column, boolValue: bv };
				discLiteral = { kind: NodeKind.BooleanLiteral, line: jv.line, column: jv.column, boolValue: bv };
			} else {
				pattern = { kind: NodeKind.StringLiteral, line: jv.line, column: jv.column, value: variantKey };
				discLiteral = { kind: NodeKind.StringLiteral, line: jv.line, column: jv.column, value: variantKey };
			}

			// Build per-variant ObjectLiteral: disc field first, then payload.
			const vKeyNodes: string[] = [discField];
			const vValueNodes: Node[] = [discLiteral];
			for (let fi = 0; fi < v.typExprFieldNames.length; fi = fi + 1) {
				const fname: string = v.typExprFieldNames[fi];
				const ftype: Node = v.typExprFieldTypes[fi];
				if (fname === discField) continue;

				if (ftype.kind !== NodeKind.Identifier) {
					error("jsonValueToStruct: DU variant payload field '" + fname + "' must be atomic (string/bool/number/int*/float*); nested struct + array deferred", witness);
				}
				const a = pickAtomicAccessor(ftype.name);
				const fieldAccess: Node = {
					kind: NodeKind.CallExpr, line: jv.line, column: jv.column,
					callee: {
						kind: NodeKind.MemberExpr, line: jv.line, column: jv.column,
						object: {
							kind: NodeKind.CallExpr, line: jv.line, column: jv.column,
							callee: { kind: NodeKind.Identifier, line: jv.line, column: jv.column, name: "getDynamicField" },
							arguments: [
								jv,
								{ kind: NodeKind.StringLiteral, line: jv.line, column: jv.column, value: fname },
							],
						},
						property: a.methodName,
					},
					arguments: [],
				};
				const finalAccess: Node = a.needsCast
					? { kind: NodeKind.TypeAssertion, line: jv.line, column: jv.column, asExpr: fieldAccess, asType: a.castType }
					: fieldAccess;
				vKeyNodes.push(fname);
				vValueNodes.push(finalAccess);
			}

			matchCases.push({
				kind: NodeKind.MatchCase, line: jv.line, column: jv.column,
				casePatterns: [pattern],
				caseGuard: null as unknown as Node,
				caseBody: {
					kind: NodeKind.ObjectLiteral, line: jv.line, column: jv.column,
					keys: vKeyNodes,
					properties: vValueNodes,
					keyLocations: [],
				},
			});
		}

		return {
			kind: NodeKind.MatchExpr, line: jv.line, column: jv.column,
			matchDisc,
			matchCases,
		};
	}

	if (tt.kind !== NodeKind.TypeObject) {
		error("jsonValueToStruct: target type must be a struct/interface; atomic types not supported", witness);
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
		// recursive jsonValueToStruct call with a typed witness `null as
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
				error("jsonValueToStruct: anonymous nested struct fields unsupported (field '" + fname + "'); name the inner struct via interface/class", witness);
			}
			// jsonValueToStruct(getDynamicField(jv, "f"), null as Inner | null)
			const recursiveCall: Node = {
				kind: NodeKind.CallExpr,
				line: jv.line,
				column: jv.column,
				callee: {
					kind: NodeKind.Identifier,
					line: jv.line,
					column: jv.column,
					name: "jsonValueToStruct",
				},
				arguments: [
					{
						kind: NodeKind.CallExpr,
						line: jv.line,
						column: jv.column,
						callee: {
							kind: NodeKind.Identifier,
							line: jv.line,
							column: jv.column,
							name: "getDynamicField",
						},
						arguments: [
							jv,
							{
								kind: NodeKind.StringLiteral,
								line: jv.line,
								column: jv.column,
								value: fname,
							},
						],
					},
					{
						kind: NodeKind.TypeAssertion,
						line: jv.line,
						column: jv.column,
						asExpr: {
							kind: NodeKind.NullLiteral,
							line: jv.line,
							column: jv.column,
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

		// Array field — V2: builtin atomic + enum/alias + struct/interface elements.
		// Builtin → per-type fast helper (jsonToXArray).
		// Non-builtin Identifier (enum / type alias) → `_jsonToIntArray<T>` generic.
		// Struct/interface → `_jsonToStructArray<T>` generic.
		// Generic-helper paths emit a bare `null` witness — T binds via Pass 3
		// contextual return-type binding (Nim parity inheritBindings,
		// semcall.nim:777-859). See bug024 for the compiler mechanism.
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
					error("jsonValueToStruct: anonymous struct element arrays unsupported (field '" + fname + "')", witness);
				}
			} else if (elemType.kind === NodeKind.TypeGeneric) {
				const peeled: Node = elemType.typExprArgs[0];
				if (peeled.kind === NodeKind.TypeObject) {
					elemIsStruct = true;
					en = peeled.typExprTypeName;
					if (en === "") {
						error("jsonValueToStruct: anonymous struct element arrays unsupported (field '" + fname + "')", witness);
					}
				} else {
					error("jsonValueToStruct: unsupported array element kind=TypeGeneric (field '" + fname + "')", witness);
				}
			} else {
				error("jsonValueToStruct: unsupported array element kind=" + elemType.kind + " (field '" + fname + "')", witness);
			}
			const isBuiltin: boolean = en === "string" || en === "boolean"
				|| en === "number" || en === "float32" || en === "float64"
				|| en === "int8" || en === "int16" || en === "int32" || en === "int64"
				|| en === "uint8" || en === "uint16" || en === "uint32";

			const getCall: Node = {
				kind: NodeKind.CallExpr,
				line: jv.line,
				column: jv.column,
				callee: {
					kind: NodeKind.Identifier,
					line: jv.line,
					column: jv.column,
					name: "getDynamicField",
				},
				arguments: [
					jv,
					{
						kind: NodeKind.StringLiteral,
						line: jv.line,
						column: jv.column,
						value: fname,
					},
				],
			};

			// Generic-helper path: enum/alias → _jsonToIntArray<T>;
			// struct/interface → _jsonToStructArray<T>. Witness is bare
			// `null` — T binds via Pass 3 contextual return-type binding
			// (Nim parity inheritBindings, semcall.nim:777-859). The
			// surrounding ObjectLiteral assignment context (`colors: ...
			// : Color[]`) flows expected return type `Color[]` to the call,
			// Pass 3 unifies `Array<T>` formal vs `Array<Color>` expected
			// → T=Color. Post-mono arg reconciliation in
			// tryInstantiateGenericCallee then wraps the bare null literal
			// into Maybe<Color> for value-type T at codegen. No
			// `as <Elem> | null` annotation needed — that path required
			// scope to see `Elem` (failed for user-file types referenced
			// from prelude macro expansion). See bug024 for full rationale.
			if (elemIsStruct || !isBuiltin) {
				const witnessNode: Node = {
					kind: NodeKind.NullLiteral,
					line: jv.line,
					column: jv.column,
					nullPlaceholder: true,
				};
				const helperName: string = elemIsStruct ? "_jsonToStructArray" : "_jsonToIntArray";
				const arrFieldAccess: Node = {
					kind: NodeKind.CallExpr,
					line: jv.line,
					column: jv.column,
					callee: {
						kind: NodeKind.Identifier,
						line: jv.line,
						column: jv.column,
						name: helperName,
					},
					arguments: [getCall, witnessNode],
				};
				keyNodes.push(fname);
				valueNodes.push(arrFieldAccess);
				i = i + 1;
				continue;
			}

			// Builtin atomic element → fast per-type helper.
			// IF-ELSE not match (Raiser VM string-match bug, see memory).
			let arrHelper: string = "jsonToInt64Array";
			if (en === "string") arrHelper = "jsonToStringArray";
			else if (en === "boolean") arrHelper = "jsonToBooleanArray";
			else if (en === "number") arrHelper = "jsonToNumberArray";
			else if (en === "float64") arrHelper = "jsonToNumberArray";
			else if (en === "float32") arrHelper = "jsonToFloat32Array";
			else if (en === "int8") arrHelper = "jsonToInt8Array";
			else if (en === "int16") arrHelper = "jsonToInt16Array";
			else if (en === "int32") arrHelper = "jsonToInt32Array";
			else if (en === "int64") arrHelper = "jsonToInt64Array";
			else if (en === "uint8") arrHelper = "jsonToUint8Array";
			else if (en === "uint16") arrHelper = "jsonToUint16Array";
			else if (en === "uint32") arrHelper = "jsonToUint32Array";
			const arrFieldAccess: Node = {
				kind: NodeKind.CallExpr,
				line: jv.line,
				column: jv.column,
				callee: {
					kind: NodeKind.Identifier,
					line: jv.line,
					column: jv.column,
					name: arrHelper,
				},
				arguments: [getCall],
			};
			keyNodes.push(fname);
			valueNodes.push(arrFieldAccess);
			i = i + 1;
			continue;
		}

		// Literal-typed field (e.g. `kind: "circle"`, `ok: true`). Bridge
		// emits StringLiteral/BooleanLiteral nodes for these. Decoded value
		// MUST equal the literal — emit the literal directly, ignore jv.
		// Pre-Bug-A bridge made these Identifier(name=value), which fell
		// through to the Identifier branch below and got mis-typed.
		if (ftype.kind === NodeKind.StringLiteral) {
			keyNodes.push(fname);
			valueNodes.push(ftype);
			i = i + 1;
			continue;
		}
		if (ftype.kind === NodeKind.BooleanLiteral) {
			keyNodes.push(fname);
			valueNodes.push({ kind: NodeKind.BooleanLiteral, line: jv.line, column: jv.column, boolValue: ftype.boolValue });
			i = i + 1;
			continue;
		}
		// Atomic field — Identifier with `.name` from mapTypeToAst's
		// atomicTypeName. Anything else is rejected.
		if (ftype.kind !== NodeKind.Identifier) {
			error("jsonValueToStruct: union fields not supported in V1; field '" + fname + "'", witness);
		}
		const a = pickAtomicAccessor(ftype.name);
		// getDynamicField(jv, "fname").<accessor>() — MemberExpr-callee style
		// so the extension dispatcher resolves the accessor.
		const fieldAccess: Node = {
			kind: NodeKind.CallExpr, line: jv.line, column: jv.column,
			callee: {
				kind: NodeKind.MemberExpr, line: jv.line, column: jv.column,
				object: {
					kind: NodeKind.CallExpr, line: jv.line, column: jv.column,
					callee: { kind: NodeKind.Identifier, line: jv.line, column: jv.column, name: "getDynamicField" },
					arguments: [
						jv,
						{ kind: NodeKind.StringLiteral, line: jv.line, column: jv.column, value: fname },
					],
				},
				property: a.methodName,
			},
			arguments: [],
		};
		const finalAccess: Node = a.needsCast
			? { kind: NodeKind.TypeAssertion, line: jv.line, column: jv.column, asExpr: fieldAccess, asType: a.castType }
			: fieldAccess;
		keyNodes.push(fname);
		valueNodes.push(finalAccess);
		i = i + 1;
	}

	return {
		kind: NodeKind.ObjectLiteral,
		line: jv.line,
		column: jv.column,
		keys: keyNodes,
		properties: valueNodes,
		keyLocations: [],
	};
}
