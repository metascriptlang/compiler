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

// Macro: jv must be a JsonValue. Witness expression must be typed `T | null`
// (e.g., user passes `null as Person | null`). Honest nullable typing — null
// is a real member of T | null, not a deceptive `null as unknown as T` lie.
// The macro peels the Union to extract T, then emits an ObjectLiteral
// constructing T from per-field accessor calls.
export macro jsonValueToStruct(jv: Node, witness: Node): Node {
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
		// All paths emit a typed witness `null as <Elem> | null` so T binds via
		// substituteType (Phase 1 fix) for explicit-`<T>` and via unifyType
		// (Phase 2 fix) for inference. We emit explicit `<Elem>` — though MS
		// CallExpr's type-arg storage is parser-keyed, the inference path
		// works thanks to bug008 bridge.
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
			// struct/interface → _jsonToStructArray<T>. Witness is
			// `null as <Elem> | null` — Phase 1+2 fixes make T bind:
			// for value Elem (Maybe<Elem>), unifyType bridges (bug008);
			// for Ref Elem (Union<Ref<Elem>, Null>), structural unify works.
			if (elemIsStruct || !isBuiltin) {
				// Emit bare `null` witness — T binds via Pass 3 contextual return-type
				// binding (Nim parity inheritBindings, semcall.nim:777-859). The
				// surrounding ObjectLiteral assignment context (`colors: ... : Color[]`)
				// flows expected return type `Color[]` to the call, Pass 3 unifies
				// `Array<T>` formal vs `Array<Color>` expected → T=Color.
				//
				// Post-mono arg reconciliation in tryInstantiateGenericCallee then
				// wraps the bare null literal into Maybe<Color> for value-type T at
				// codegen. No `as <Elem> | null` annotation needed — that path
				// required scope to see `Elem` (failed for user-file types referenced
				// from prelude macro expansion).
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

		// Atomic field — Identifier with `.name` from mapTypeToAst's
		// atomicTypeName. Anything else is rejected.
		if (ftype.kind !== NodeKind.Identifier) {
			error("jsonValueToStruct: union fields not supported in V1; field '" + fname + "'", witness);
		}
		const tn: string = ftype.name;

		// Pick the bridge accessor for this atomic type. asString / asBoolean /
		// asNumber / asInt64 each handle the runtime kind dispatch — crucial for
		// numbers because the parser stores `30` as JsonKind.Int (intVal slot)
		// and `30.5` as JsonKind.Number (numVal slot). Direct slot access
		// (.numVal / .intVal) reads uninitialized memory when the kind doesn't
		// match.
		//
		// Sized-int / enum / int-aliased fields go through asInt64 + TypeAssertion
		// to narrow int64 → declared field type (int8 / int32 / Color enum / etc.).
		// `number` field accepts either Int or Number JSON variants via asNumber.
		const accessorName: string = match (tn) {
			"string" => "asString",
			"boolean" => "asBoolean",
			"number" | "float32" | "float64" => "asNumber",
			_ => "asInt64",   // sized int / uint / enum / int-aliased
		};
		// Only emit explicit TypeAssertion for builtin-named narrowing
		// (`int8`/`int16`/.../`uint*`/`float32`). For user-defined names —
		// enums, type aliases — skip the cast: the surrounding ObjectLiteral
		// assignment context-types each property and fitNode inserts
		// HiddenStdConv (range-check / implicit cast) for the int64→<field>
		// narrowing. A TypeAssertion-by-name fails to resolve when the macro
		// expands inside a generic helper's monomorphized body whose scope
		// doesn't include user-defined types — see Bug 53 root cause.
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

		// getDynamicField(jv, "fname").<accessorName>()
		// MemberExpr-callee style so the extension dispatcher resolves the
		// accessor; Identifier-callee style fails because extensions are only
		// reachable via member-call form.
		const fieldAccess: Node = {
			kind: NodeKind.CallExpr,
			line: jv.line,
			column: jv.column,
			callee: {
				kind: NodeKind.MemberExpr,
				line: jv.line,
				column: jv.column,
				object: {
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
				property: accessorName,
			},
			arguments: [],
		};

		// Cast narrows the bridge accessor's wide return (int64 / number) down
		// to the declared field type — int32, float32, Color enum, alias, etc.
		const finalAccess: Node = needsCast
			? {
				kind: NodeKind.TypeAssertion,
				line: jv.line,
				column: jv.column,
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
		line: jv.line,
		column: jv.column,
		keys: keyNodes,
		properties: valueNodes,
		keyLocations: [],
	};
}
