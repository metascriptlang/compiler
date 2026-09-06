// Discriminator detection for tagged-union (DU) types.
//
// Shared between JSON/CBOR encode + decode macros. Combines two information
// sources:
//   1. Bridge-populated fields on TypeUnion node (discFieldName, variantKeys,
//      discKind) — populated for match-type DUs and generic-DU peeled types
//      (Result, Option) by src/compiler/meta/bridge.ms unionToAst.
//   2. TS-style auto-detect — for plain `{kind:"a"} | {kind:"b"}` unions
//      where bridge has no info: walk variants for a shared literal-typed
//      disc field, extract the disc value from each variant's disc-field
//      type, and infer kind (boolean/enum/string) from the first key shape.
//
// Returns a DiscInfo with paired (key, member) variants — no parallel-list
// indexing fragility. Empty discField or variants means detection failed —
// caller should error("cannot determine discriminator…").
//
// Called only from inside macro bodies (jsonValueOf, jsonValueToStruct, etc.).
// Macro VM passes Node arguments as flat-field heap objects, so we cast each
// Node to its NodeData variant via `as unknown as XData` to satisfy the type
// checker; the runtime heap lookup for the named field works because the
// bridge serializes data fields at the top level (see bridge.ms nodeToValue).
import { Node, NodeKind, TypeUnionData, TypeGenericData, TypeObjectData, IdentifierData,
	StringLiteralData, BooleanLiteralData,
	CallExprData, MemberExprData, TypeAssertionData,
	createNodeAt, makeLoc,
	SourceLocation } from "std/meta";

export interface DiscVariant {
	key: string;     // disc value: "circle" | "true" | "Click" etc.
	member: Node;    // peeled variant struct (TypeObject; no Ref wrapper)
}

export interface DiscInfo {
	discField: string;
	discKind: string;
	variants: DiscVariant[];
}

// ===== Disc-key parsing =====
// Splits a `variantKey` into the parts needed by codec encoders to build
// the per-variant pattern + disc-value AST. For `discKind="enum"`, the
// bridge encodes variant keys as `"EnumName.MemberName"` (one string with a
// dot separator) — caller needs both halves. For boolean/string disc,
// `variantKey` is the literal value verbatim.
//
// Shared between JSON + CBOR encode DU branches.
export interface DiscKeyParts {
	boolValue: boolean;     // for discKind="boolean": true if variantKey === "true"
	enumName: string;       // for discKind="enum": "K" from "K.A" (else "")
	memberName: string;     // for discKind="enum": "A" from "K.A" (else == variantKey)
}

export function parseDiscKey(discKind: string, variantKey: string): DiscKeyParts {
	if (discKind == "boolean") {
		return { boolValue: variantKey == "true", enumName: "", memberName: "" };
	}
	if (discKind == "enum") {
		// Inline dot-search ("K.A" → enumName="K", memberName="A")
		let dotIdx: int32 = -1;
		for (let ci: int32 = 0; ci < variantKey.length; ci = ci + 1) {
			if (variantKey.slice(ci, ci + 1) == ".") { dotIdx = ci; break; }
		}
		if (dotIdx > 0) {
			return {
				boolValue: false,
				enumName: variantKey.slice(0, dotIdx),
				memberName: variantKey.slice(dotIdx + 1, variantKey.length),
			};
		}
		return { boolValue: false, enumName: "", memberName: variantKey };
	}
	// "string" disc (default) — pattern + value use variantKey verbatim
	return { boolValue: false, enumName: "", memberName: variantKey };
}

// ===== Atomic-field accessor dispatch =====
// Shared between JSON/CBOR decode struct path + DU variant payload path.
// Both codecs use the SAME accessor names on JsonValue/CborValue:
// asString / asBoolean / asNumber / asInt64. Sized-int / enum / int-aliased
// fields go through asInt64 + TypeAssertion to narrow int64 → declared field
// type. Builtin-narrow-name only — for user-defined names (enums, aliases),
// surrounding ObjectLiteral context inserts the implicit conversion
// (HiddenStdConv); naming the type in a TypeAssertion fails to resolve when
// the macro expands inside a generic helper's monomorphized body. See
// Bug 53 root cause.
//
// AST construction stays at each call site (inside macro body) so flat-shape
// node literals type-check. This helper is a regular function — moving AST
// construction here would require canonical createNodeAt + cast hacks.
export interface AtomicAccessor {
	methodName: string;     // "asString" | "asBoolean" | "asNumber" | "asInt64"
	needsCast: boolean;     // wrap result in TypeAssertion?
	castType: string;       // empty when needsCast is false
}

// ===== AST builders for getDynamicField + accessor + cast pattern =====
// Used by JSON + CBOR decode struct path AND DU variant payload path.
// Canonical createNodeAt builders — no flat-shape literal construction
// (which fails type check in regular function context).
//
// Composable shape:
//   emitGetDynamicField(jv, "f", L, C)            → getDynamicField(jv, "f")
//   emitMethodCall(<above>, "asString", L, C)     → ....asString()
//   emitTypeAssertion(<above>, "int32", L, C)     → ... as int32

export function emitGetDynamicField(target: Node, fieldName: string, line: int32, column: int32): Node {
	const loc: SourceLocation = makeLoc(line, column);
	const fnIdent = createNodeAt(NodeKind.Identifier, { name: "getDynamicField" } as IdentifierData, loc);
	const nameLit = createNodeAt(NodeKind.StringLiteral, { value: fieldName } as StringLiteralData, loc);
	return createNodeAt(NodeKind.CallExpr, {
		callee: fnIdent,
		arguments: [target, nameLit],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	} as CallExprData, loc);
}

// Build `target.methodName()` — MemberExpr-callee CallExpr (extension dispatch).
export function emitMethodCall(target: Node, methodName: string, line: int32, column: int32): Node {
	const loc: SourceLocation = makeLoc(line, column);
	const member = createNodeAt(NodeKind.MemberExpr, {
		object: target,
		property: methodName,
		isOptional: false,
	} as MemberExprData, loc);
	return createNodeAt(NodeKind.CallExpr, {
		callee: member,
		arguments: [],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	} as CallExprData, loc);
}

// Build `expr as TypeName` wrapper — narrowing cast around accessor result.
export function emitTypeAssertion(expr: Node, asType: string, line: int32, column: int32): Node {
	const loc: SourceLocation = makeLoc(line, column);
	return createNodeAt(NodeKind.TypeAssertion, {
		asExpr: expr,
		asType: asType,
	} as TypeAssertionData, loc);
}

export function pickAtomicAccessor(tn: string): AtomicAccessor {
	const methodName: string = match (tn) {
		"string" => "asString",
		"boolean" => "asBoolean",
		"number" | "float32" | "float64" => "asNumber",
		_ => "asInt64",   // sized int / uint / enum / int-aliased
	};
	const isBuiltinNarrow: boolean = match (tn) {
		"int8" | "int16" | "int32" | "int64"
			| "uint8" | "uint16" | "uint32" | "uint64"
			| "float32" => true,
		_ => false,
	};
	const needsCast: boolean = match (tn) {
		"string" | "boolean" | "number" | "float64" => false,
		_ => isBuiltinNarrow,
	};
	return { methodName, needsCast, castType: needsCast ? tn : "" };
}

// Peel Ref<Struct> → Struct for variant inspection. Variants come from
// tt.typExprMembers; generic-instance variants land as TypeGeneric wrappers.
function peelVariant(vRaw: Node): Node {
	if (vRaw.kind == NodeKind.TypeGeneric) {
		const gd: TypeGenericData = vRaw as unknown as TypeGenericData;
		return gd.typExprArgs[0];
	}
	return vRaw;
}

// Find disc-field literal value for a peeled variant. Returns "" if the
// variant doesn't have the field, or the field type isn't a literal type.
// Bridge emits StringLiteral/BooleanLiteral nodes for literal types
// (`kind: "circle"` → StringLiteral{value:"circle"}; `ok: true` →
// BooleanLiteral{boolValue:true}). Pre-2026-05-15 bridge fell through to
// Identifier(name=literal_value) — kept here as fallback for any caller
// that bypasses the new bridge cases.
function extractVariantKey(v: Node, discField: string): string {
	if (v.kind != NodeKind.TypeObject) return "";
	const od: TypeObjectData = v as unknown as TypeObjectData;
	for (let fi = 0; fi < od.typExprFieldNames.length; fi = fi + 1) {
		if (od.typExprFieldNames[fi] == discField) {
			const ft: Node = od.typExprFieldTypes[fi];
			if (ft.kind == NodeKind.StringLiteral) {
				const sd: StringLiteralData = ft as unknown as StringLiteralData;
				return sd.value;
			}
			if (ft.kind == NodeKind.BooleanLiteral) {
				const bd: BooleanLiteralData = ft as unknown as BooleanLiteralData;
				return bd.boolValue ? "true" : "false";
			}
			if (ft.kind == NodeKind.Identifier) {
				const id: IdentifierData = ft as unknown as IdentifierData;
				return id.name;
			}
			return "";
		}
	}
	return "";
}

// `T | null` witnesses (common decode pattern) carry a literal `null`
// Identifier alongside real variants. The null arm isn't a real DU variant —
// drop it so auto-detect / variant building treats only the typed members.
function isNullVariant(m: Node): boolean {
	if (m.kind != NodeKind.Identifier) return false;
	const id: IdentifierData = m as unknown as IdentifierData;
	return id.name == "null";
}

export function detectUnionDisc(tt: Node): DiscInfo {
	const ttd: TypeUnionData = tt as unknown as TypeUnionData;
	let discField: string = ttd.discFieldName;
	let discKind: string = ttd.discKind;

	const realMembers: Node[] = [];
	for (const m of ttd.typExprMembers) {
		if (!isNullVariant(m)) realMembers.push(m);
	}

	// Step 1: auto-detect discFieldName by walking variant[0]'s field names
	// and confirming each candidate exists in ALL other variants (skip [0]
	// since the candidate came from it). Requires ≥2 variants — a DU by
	// definition has multiple variants; with only 1 the inner-loop never
	// iterates and we'd vacuously pick variant[0]'s first field as disc.
	if (discField == "" && realMembers.length >= 2) {
		const v0: Node = peelVariant(realMembers[0]);
		if (v0.kind == NodeKind.TypeObject) {
			const v0d: TypeObjectData = v0 as unknown as TypeObjectData;
			for (const candidate of v0d.typExprFieldNames) {
				let foundInAll: boolean = true;
				for (let vi = 1; vi < realMembers.length; vi = vi + 1) {
					const v: Node = peelVariant(realMembers[vi]);
					if (v.kind != NodeKind.TypeObject) { foundInAll = false; break; }
					const vd: TypeObjectData = v as unknown as TypeObjectData;
					let inV: boolean = false;
					for (const f of vd.typExprFieldNames) {
						if (f == candidate) { inV = true; break; }
					}
					if (!inV) { foundInAll = false; break; }
				}
				if (foundInAll) { discField = candidate; break; }
			}
		}
	}

	// Step 2: build paired (key, member) variants. Two paths:
	//   (a) Bridge already populated tt.variantKeys — pair with typExprMembers
	//       by index (bridge guarantees same length + order).
	//   (b) Auto-extract: walk realMembers, derive key from each variant's
	//       disc-field literal type. Variants that fail to yield a key are
	//       SKIPPED (kept out of variants[]) — no parallel-list misalignment
	//       downstream because key + member always travel together.
	const variants: DiscVariant[] = [];
	if (ttd.variantKeys.length > 0) {
		for (let vi = 0; vi < ttd.variantKeys.length; vi = vi + 1) {
			const member: Node = peelVariant(ttd.typExprMembers[vi]);
			variants.push({ key: ttd.variantKeys[vi], member });
		}
	} else if (discField != "") {
		for (const vRaw of realMembers) {
			const member: Node = peelVariant(vRaw);
			const key: string = extractVariantKey(member, discField);
			if (key != "") {
				variants.push({ key, member });
			}
		}
	}

	// Step 3: infer discKind from first variant key shape.
	// "true"/"false" → boolean. Enum-like ("EnumName.Member") comes from the
	// bridge, which stamps discKind for every enum-discriminated union — the
	// match-type form and (since the resolvePass auto-stamp) the TS-style form.
	if (discKind == "" && variants.length > 0) {
		const k0: string = variants[0].key;
		if (k0 == "true" || k0 == "false") discKind = "boolean";
	}

	return { discField: discField, discKind: discKind, variants: variants };
}
