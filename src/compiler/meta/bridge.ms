// src/compiler/meta/bridge.ms
//
// AST Node ↔ Raiser VM RaiserValue serialization bridge.
//
// Macros run in the Raiser VM, which only knows primitives, arrays, and heap
// objects — not Node structs. This module bridges the two worlds:
//
//   nodeToValue:  Node    → RaiserValue (heap Object with named fields)
//   valueToNode:  RaiserValue → Node    (deserialize back)
//
// Used by:
//   - src/compiler/comptime.ms — @comptime block evaluation
//   - src/compiler/meta/expand.ms — (future) macro expansion pass
//
// Macro authors never call these directly. The compiler invokes them at the
// VM boundary when serializing macro inputs and deserializing macro outputs.
//
// Why serialize at all? The Raiser VM is intentionally DRC-free with its own
// memory model. Adding a NodeRef variant to RaiserValue would force lifetime
// tracking through the VM heaps. Serialization keeps the VM pure.

import {
	Node, NodeKind, SourceLocation, makeLoc, createNode, createNodeAt, DeclKind, ExternKind,
	// Type system (for mapTypeToAst — Phase A1 SERIALIZE)
	Type, TypeKind, TypeFlag, CallingConvention,
	// Symbol — Day 9 SERIALIZE: surface name + kind to macro VM
	Symbol, SymbolKind, SymbolState,
	// Literals
	NumberLiteralData, StringLiteralData, BooleanLiteralData,
	BigIntLiteralData, RegexLiteralData,
	// Expressions
	IdentifierData, BinaryExprData, UnaryExprData, UpdateExprData,
	CallExprData, MemberExprData, ArrayAccessData,
	ObjectLiteralData, ArrayLiteralData,
	ArrowFunctionData, FunctionExprData, TypeAssertionData,
	ConditionalExprData, SpreadExprData, NewExprData,
	TryExprData, MatchExprData, MatchCaseData,
	AwaitExprData, YieldExprData, MoveExprData, OutExprData, SizeofExprData,
	HiddenDerefData, QuoteExprData, ComptimeBlockData,
	// Patterns
	ArrayPatternData, ObjectPatternData, ObjectPatternPropData, DestructuringDeclData,
	// Statements
	ExprStmtData, ReturnStmtData, ThrowStmtData, DeferStmtData,
	VariableDeclData, IfStmtData, WhileStmtData, DoWhileStmtData,
	ForStmtData, ForOfStmtData, ForInStmtData,
	BlockStmtData, FunctionDeclData,
	SwitchStmtData, SwitchCaseData, MatchStmtData,
	TryCatchStmtData, BreakStmtData, ContinueStmtData, UnreachableStmtData,
	TestDeclData, AssertStmtData,
	// Declarations
	ImportDeclData, ExportDeclData, TypeAliasDeclData, EnumDeclData,
	InterfaceDeclData, ClassDeclData, ActorDeclData, PropertyDeclData,
	MethodDeclData, ConstructorDeclData,
	ExternDeclData, MacroDeclData, DecoratedDeclData,
	MacroInvocationData, TypeAnnotationData,
	ProgramData,
	// Type AST data shapes — Day 8 nodeToValue dispatch for synthesized type nodes
	TypeObjectData, TypeArrayData, TypeUnionData, TypeIntersectionData, TypeGenericData, TypeFunctionData,
	// SERIALIZE A2 — macro multi-decl emission
	SpliceManyData,
	// JSX (compile-time only — needs round-trip through macro VM)
	JSXElementData, JSXFragmentData, JSXTextData, JSXExpressionContainerData, JSXAttributeData, JSXSpreadAttributeData,
} from "../../ast/node";
import { Token, TokenKind, createToken } from "../../lexer/token";
// V3 — peel Union-backed generics (Result<T,E>, Option<T>) so codec macros see
// substituted variants + disc info. Lazy-instantiate pattern from destructorLifting.
import { instantiateGenericBody } from "../../checker/types";
import { getGenericDecl } from "../../parser/context";
import {
	RaiserValueKind, RaiserValue,
	RaiserObjectHeap, RaiserArrayHeap,
	heapArrayGet, heapArrayLen, raiserInt, raiserFloat, raiserBool, raiserString, raiserNil, raiserObject, raiserArray,
	heapAllocObject, heapObjectSetField, heapObjectGetField, heapAllocArray, heapArrayPush,
	createStructHeap, createArrayHeap,
} from "../../raiser/value";

// ===== Synthetic location/token helpers =====

export function synthToken(loc: SourceLocation): Token {
	return createToken(TokenKind.Ident, "", loc.line);
}

export function mkNumber(val: number, loc: SourceLocation): Node {
	return createNode(NodeKind.NumberLiteral, { value: val, isFloat: val % 1 !== 0 }, synthToken(loc));
}

export function mkString(val: string, loc: SourceLocation): Node {
	return createNode(NodeKind.StringLiteral, { value: val }, synthToken(loc));
}

export function mkBool(val: boolean, loc: SourceLocation): Node {
	return createNode(NodeKind.BooleanLiteral, { boolValue: val }, synthToken(loc));
}

export function mkNull(loc: SourceLocation): Node {
	return createNode(NodeKind.NullLiteral, { nullPlaceholder: true }, synthToken(loc));
}

// ===== mapTypeToAst — Type → Node tree =====
//
// Mirrors reference's `mapTypeToAstX` (vmdeps.nim:100-336). Converts compiler-
// internal Type to a Node tree representing the type as AST, so macros can walk
// type info using existing AST primitives (TypeObject, TypeGeneric, etc.).
//
// Default mode is "getTypeImpl" equivalent: full implementation expand,
// recursion through named types, no alias peeling. (4 explicit view modes
// deferred to V2 — current API exposes via node.nodeType field after bridge
// integration.)
//
// V1 progress (Phase A1):
//   Day 1 — atomic types (primitives) — DONE
//   Day 2 — Struct (Interface/Class/Struct) — pending
//   Day 3 — Array, SizedArray, Span — pending
//   Day 4 — GenericInstance, GenericParam — pending
//   Day 5 — cycle handling (recursion gate + identity dedup) — pending
//   Week 2 — Union, Ref/modifiers, bridge integration — pending
//   Week 3 — decorators, cross-module — pending

// Map a primitive TypeKind to its source-spelling name. Returns "" for non-primitive.
function atomicTypeName(t: Type): string {
	return match (t.kind) {
		TypeKind.String  => "string",
		TypeKind.Number  => "number",
		TypeKind.Boolean => "boolean",
		TypeKind.Void    => "void",
		TypeKind.Char    => "char",
		TypeKind.Null    => "null",
		TypeKind.Unknown => "unknown",
		TypeKind.Never   => "never",
		TypeKind.Int8    => "int8",
		TypeKind.Int16   => "int16",
		TypeKind.Int32   => "int32",
		TypeKind.Int64   => "int64",
		TypeKind.Uint8   => "uint8",
		TypeKind.Uint16  => "uint16",
		TypeKind.Uint32  => "uint32",
		TypeKind.Uint64  => "uint64",
		TypeKind.Float32 => "float32",
		TypeKind.Float64 => "float64",
		TypeKind.CString => "cstring",
		TypeKind.Error   => "<error>",
		_ => "",
	};
}

// Build an atomic type node (NodeKind.Identifier with name).
// Reuses Identifier for type leaf nodes — see node.ms:355 comment.
function atomicTypeNode(name: string, loc: SourceLocation): Node {
	return createNodeAt(NodeKind.Identifier, { name }, loc);
}

// Recurse mapTypeToAst across an array of Types. Single chokepoint for child-type
// expansion — threads the visited stack so cycles are detected uniformly.
function mapTypes(types: Type[], loc: SourceLocation, visited: Type[]): Node[] {
	const out: Node[] = [];
	for (const t of types) {
		out.push(mapTypeToAstWith(t, loc, visited));
	}
	return out;
}

// Pick t.typeName when set, else the kind-specific fallback sentinel.
function nameOrDefault(t: Type, fallback: string): string {
	return t.typeName !== "" ? t.typeName : fallback;
}

// Cycle detection — linear scan over the visiting stack (typically <10 deep).
// Reference identity: same Type instance, not structural equality.
function isVisiting(visited: Type[], t: Type): boolean {
	for (const v of visited) {
		if (v === t) return true;
	}
	return false;
}

// Walk a class body to find decorators attached to each named property.
// Returns a parallel array (length = fieldNames.length) where [i] = decorator
// nodes for field i, or [] if that field has no decorators.
//
// Source shape:
//   class User {
//       @rename("_id") id: string;     // decorated
//       name: string;                  // not decorated
//   }
//
// The class body holds Node[] members. A decorated property is wrapped:
//   DecoratedDecl { decorators: [...], decoratedNode: PropertyDecl }
// Static fields and methods are skipped (V2 scope: instance fields only).
//
// Inheritance limit: parent-class fields appear in `t.typeNames` but NOT in
// `cd.classBody` of the child — they get empty decorator slots. Codec macros
// see decorators only for fields declared directly on the class. V3 may walk
// the inheritance chain.
function collectFieldDecorators(t: Type): Node[][] {
	const out: Node[][] = [];
	for (let i = 0; i < t.typeNames.length; i = i + 1) out.push([]);

	if (t.sym === null || t.sym.declNode === null) return out;
	let decl = t.sym.declNode;
	// Peel ExportDecl wrapper if present (e.g., `export class User { ... }`)
	if (decl.kind === NodeKind.ExportDecl) {
		const ed = decl.data as ExportDeclData;
		if (ed.exportedDecl !== null) decl = ed.exportedDecl;
	}
	if (decl.kind !== NodeKind.ClassDecl) return out;

	const cd = decl.data as ClassDeclData;
	// Walk classBody, collect (propName → decorators) for non-static properties
	for (const member of cd.classBody) {
		if (member === null) continue;
		let inner = member;
		let decorators: Node[] = [];
		if (member.kind === NodeKind.DecoratedDecl) {
			const dd = member.data as DecoratedDeclData;
			decorators = dd.decorators;
			if (dd.decoratedNode !== null) inner = dd.decoratedNode;
		}
		if (inner.kind !== NodeKind.PropertyDecl) continue;
		const pd = inner.data as PropertyDeclData;
		if (pd.propIsStatic) continue;
		// Find the field index in t.typeNames and store decorators at that slot
		for (let j = 0; j < t.typeNames.length; j = j + 1) {
			if (t.typeNames[j] === pd.propName) {
				out[j] = decorators;
				break;
			}
		}
	}
	return out;
}

// Build a TypeObject node for a Struct (interface / class / struct) Type.
// Reads parallel arrays t.typeNames (field names) + t.typeChildren (field types).
// Decorators (V2): for ClassDecl-backed types, walk the class body to surface
// per-field decorator nodes. Other Type sources (interface, anon struct,
// generic instantiation) get empty arrays.
function structToAst(t: Type, loc: SourceLocation, visited: Type[]): Node {
	return createNodeAt(NodeKind.TypeObject, {
		typExprFieldNames: t.typeNames,
		typExprFieldTypes: mapTypes(t.typeChildren, loc, visited),
		typExprIndexKey: null as unknown as Node,
		typExprIndexValue: null as unknown as Node,
		typExprFieldDecorators: collectFieldDecorators(t),
		typExprTypeName: t.typeName,
	}, loc);
}

// Build a TypeArray node for Array<T> / SizedArray<T,N> / Span<T>.
// Size encoding: SizedArray reads t.typeFlags (raw int size). Array and Span
// emit -1 (unsized sentinel — see node.ms:357). Array vs Span distinction is
// intentionally lost in the AST per plan.
//
// Substituting flag mask: SizedArray.typeFlags can co-locate the size with
// the TypeFlag.Substituting bit (node.ms:51 confirms intentional layout). If
// the macro VM somehow sees a mid-substitution Type, the raw flags would
// add 1048576 to the reported size. Mask defensively.
function arrayToAst(t: Type, loc: SourceLocation, visited: Type[]): Node {
	const size: number = t.kind === TypeKind.SizedArray
		? (t.typeFlags & ~TypeFlag.Substituting) as number
		: -1;
	return createNodeAt(NodeKind.TypeArray, {
		typExprElement: mapTypeToAstWith(t.typeReturn, loc, visited),
		typExprSize: size,
	}, loc);
}

// Build a TypeGeneric node for a GenericInstance (e.g., Container<int32>).
// Surfaces the generic structure to macros (base name + type args) rather than
// expanding the instantiated body. Codec macros typically introspect the type
// parameters; the concrete body is reachable separately via the base symbol.
function genericToAst(t: Type, loc: SourceLocation, visited: Type[]): Node {
	return createNodeAt(NodeKind.TypeGeneric, {
		typExprBase: atomicTypeNode(nameOrDefault(t, "<anon-generic>"), loc),
		typExprArgs: mapTypes(t.typeChildren, loc, visited),
	}, loc);
}

// V3 — Union-backed generics (Result<T,E>, Option<T>) get peeled
// so codec macros see substituted variants + disc info instead of opaque
// TypeGeneric. Non-Union-backed generics (Container<T>, Map<K,V>, Promise<T>)
// fall through to standard genericToAst.
//
// Lazy-instantiate pattern from src/transform/lowering/destructorLifting.ms:128 —
// idempotent (gated on typeReturn === null), proven elsewhere in compiler.
function genericInstanceToAst(t: Type, loc: SourceLocation, visited: Type[]): Node {
	if (t.typeExtra !== null && t.typeExtra.kind === TypeKind.Union) {
		if (t.typeReturn === null) {
			const decl = getGenericDecl(t.typeName);
			if (decl !== "") instantiateGenericBody(t, decl);
		}
		if (t.typeReturn !== null && t.typeReturn.kind === TypeKind.Union) {
			return unionToAst(t.typeReturn, loc, visited);
		}
	}
	return genericToAst(t, loc, visited);
}

// Build a TypeUnion node for `A | B | C` types. typeChildren holds the variant
// types after the checker's flatten + dedup pass (see createUnion in types.ms).
//
// V3: surface discriminator metadata when checker pre-stored it
// in t.typeNames + t.typeExtra. Two populate paths:
//   1. match-type DUs (`type V = match (k: K) { ... }`) — populated by
//      resolveDiscriminatedUnion in resolvePass.ms
//   2. Result<T,E> / Option<T> — peeled by genericInstanceToAst (above) which
//      calls unionToAst on the substituted underlying Union
// TS-style DUs (`{kind:"a"} | {kind:"b"}`) have at most disc field name (no
// variant keys) — codecs walk variants directly to enumerate disc values.
// See checker/types.ms isDiscriminatedUnion.
function unionToAst(t: Type, loc: SourceLocation, visited: Type[]): Node {
	let discField: string = "";
	const variantKeys: string[] = [];
	let discKind: string = "";
	if (t.typeExtra !== null && t.typeNames !== null && t.typeNames.length > 0) {
		discField = t.typeNames[0];
		// typeNames[1+] hold the variant keys ("K.A","K.B" for enum disc;
		// "true","false" for boolean disc). Format kept verbatim — encode
		// macros decide how to render in target format.
		let i = 1;
		while (i < t.typeNames.length) {
			variantKeys.push(t.typeNames[i]);
			i = i + 1;
		}
		discKind = match (t.typeExtra.kind) {
			TypeKind.Boolean => "boolean",
			TypeKind.Enum => "enum",
			_ => "",
		};
	}
	return createNodeAt(NodeKind.TypeUnion, {
		typExprMembers: mapTypes(t.typeChildren, loc, visited),
		discFieldName: discField,
		variantKeys,
		discKind,
	}, loc);
}

// Wrapper-style modifier name lookup: Ref<T>, Ptr<T>, Sink<T>, etc.
// All 7 modifier kinds store the inner type in t.typeReturn (uniform shape).
function modifierName(kind: TypeKind): string {
	return match (kind) {
		TypeKind.Ref      => "Ref",
		TypeKind.Ptr      => "Ptr",
		TypeKind.Borrow   => "Borrow",
		TypeKind.Sink     => "Sink",
		TypeKind.Lent     => "Lent",
		TypeKind.Var      => "Var",
		TypeKind.Distinct => "Distinct",
		_ => "<modifier>",
	};
}

// Build a TypeGeneric wrapper for ownership / pointer modifier types.
// Output shape: TypeGeneric(Identifier("Ref"), [innerType]). Codec macros can
// detect the modifier name via the base Identifier and walk the inner via args[0].
function modifierToAst(t: Type, loc: SourceLocation, visited: Type[]): Node {
	return createNodeAt(NodeKind.TypeGeneric, {
		typExprBase: atomicTypeNode(modifierName(t.kind), loc),
		typExprArgs: [mapTypeToAstWith(t.typeReturn, loc, visited)],
	}, loc);
}

// Fallback for not-yet-handled non-atomic kinds: surface t.typeName (placeholder)
// or "unknown" sentinel. Replaced as Week 2 handlers land (Union, Ref/modifiers).
function fallbackTypeName(t: Type, loc: SourceLocation): Node {
	return atomicTypeNode(nameOrDefault(t, "unknown"), loc);
}

// Internal dispatch — threads the `visited` stack for cycle detection.
// Aliases peel transparently. Already-visiting Types emit a name-only Identifier
// to break the cycle (e.g., `Tree { children: Tree[] }` → outer Tree expands,
// inner reference back to Tree hits the visited check and emits Identifier("Tree")).
function mapTypeToAstWith(t: Type | null, loc: SourceLocation, visited: Type[]): Node {
	if (t === null) return atomicTypeNode("<null>", loc);

	const atomicName = atomicTypeName(t);
	if (atomicName !== "") return atomicTypeNode(atomicName, loc);

	// Cycle break — emit name placeholder and stop descending.
	// Pre-push check so Alias peel below also benefits (e.g., `type X = X`).
	if (isVisiting(visited, t)) {
		return atomicTypeNode(nameOrDefault(t, "<cycle>"), loc);
	}

	visited.push(t);
	const result: Node = match (t.kind) {
		TypeKind.Alias => t.typeReturn !== null
			? mapTypeToAstWith(t.typeReturn, loc, visited)
			: fallbackTypeName(t, loc),
		TypeKind.Struct => structToAst(t, loc, visited),
		TypeKind.Array | TypeKind.SizedArray | TypeKind.Span => arrayToAst(t, loc, visited),
		TypeKind.GenericInstance => genericInstanceToAst(t, loc, visited),
		TypeKind.GenericParam => atomicTypeNode(nameOrDefault(t, "T"), loc),
		TypeKind.Union => unionToAst(t, loc, visited),
		// Literal types — emit as their literal Node kind so consumers can
		// distinguish a literal value from a type-name Identifier. Without
		// this, `kind: "circle"` (StringLiteral type with typeName="circle")
		// became `Identifier(name="circle")`, indistinguishable from a user-
		// defined type alias named `circle`. Consumers like JSON encode then
		// fell through to the int-cast jsonInt branch, generating bad C
		// (cast msString → int64). See bug028 for the regression test.
		TypeKind.StringLiteral => createNodeAt(NodeKind.StringLiteral, { value: nameOrDefault(t, "") }, loc),
		TypeKind.BooleanLiteral => createNodeAt(NodeKind.BooleanLiteral, { boolValue: nameOrDefault(t, "") === "true" }, loc),
		TypeKind.Ref | TypeKind.Ptr | TypeKind.Borrow | TypeKind.Sink | TypeKind.Lent | TypeKind.Var | TypeKind.Distinct
			=> modifierToAst(t, loc, visited),
		_ => fallbackTypeName(t, loc),
	};
	visited.pop();
	return result;
}

// Public entry — Type → Node tree.
//
// V1 progress (Phase A1):
//   Day 1: atomic primitives → Identifier (DONE)
//   Day 2: Struct → TypeObject (DONE)
//   Day 3: Array, SizedArray, Span → TypeArray (DONE)
//   Day 4: GenericInstance → TypeGeneric, GenericParam → Identifier (DONE)
//   Day 5: Alias peel + identity-dedup cycle handling (DONE)
//   Day 6: Union → TypeUnion (DONE)
//   Day 7: Ref/Ptr/Sink/Lent/Var/Borrow/Distinct → TypeGeneric wrapper (DONE)
//
// Recursion gate (`inst && !allowRecursion && t.sym !== null`) deferred to V2 —
// only relevant when exposing getTypeInst. Default V1 mode is always
// allowRecursion=true (getTypeImpl-like for fields, getTypeInst-like for the
// generic structure surfaced at GenericInstance).
export function mapTypeToAst(t: Type | null, loc: SourceLocation): Node {
	return mapTypeToAstWith(t, loc, []);
}

// ===== Serialization helpers (write to RaiserValue) =====

function serializeNodes(nodes: Node[], objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap): RaiserValue {
	const handle = heapAllocArray(arrHeap);
	for (const node of nodes) {
		const v = nodeToValue(node, objHeap, arrHeap);
		heapArrayPush(arrHeap, handle, v);
	}
	return raiserArray(handle);
}

function serializeStrings(strs: string[], arrHeap: RaiserArrayHeap): RaiserValue {
	const handle = heapAllocArray(arrHeap);
	for (const s of strs) {
		const v = raiserString(s);
		heapArrayPush(arrHeap, handle, v);
	}
	return raiserArray(handle);
}

function setStr(objHeap: RaiserObjectHeap, h: number, name: string, val: string): void {
	const v = raiserString(val);
	heapObjectSetField(objHeap, h, name, v);
}

function setBool(objHeap: RaiserObjectHeap, h: number, name: string, val: boolean): void {
	const v = raiserBool(val);
	heapObjectSetField(objHeap, h, name, v);
}

function setNode(objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap, h: number, name: string, child: Node): void {
	if (child === null) {
		// Represent null Node fields as RaiserValue.Nil — readNode handles this on the way back
		heapObjectSetField(objHeap, h, name, raiserNil());
		return;
	}
	const v = nodeToValue(child, objHeap, arrHeap);
	heapObjectSetField(objHeap, h, name, v);
}

function setNodes(objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap, h: number, name: string, children: Node[]): void {
	const v = serializeNodes(children, objHeap, arrHeap);
	heapObjectSetField(objHeap, h, name, v);
}

function setStrs(objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap, h: number, name: string, strs: string[]): void {
	const v = serializeStrings(strs, arrHeap);
	heapObjectSetField(objHeap, h, name, v);
}

// V2 — serialize Node[][] as an array-of-arrays. Each inner array becomes a
// heap array containing serialized Node values; the outer array contains
// references to those inner arrays.
function setNodeArrays(objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap, h: number, name: string, arrays: Node[][]): void {
	const outerHandle = heapAllocArray(arrHeap);
	for (const inner of arrays) {
		const innerVal = serializeNodes(inner, objHeap, arrHeap);
		heapArrayPush(arrHeap, outerHandle, innerVal);
	}
	heapObjectSetField(objHeap, h, name, raiserArray(outerHandle));
}

// Day 9 — minimal Symbol → RaiserValue. Surfaces name + kind only.
// `declNode` skipped to avoid Symbol↔Node cycle; V2 if codecs need decl site.
function symbolToValue(sym: Symbol, objHeap: RaiserObjectHeap): RaiserValue {
	const handle = heapAllocObject(objHeap);
	setStr(objHeap, handle, "name", sym.name);
	heapObjectSetField(objHeap, handle, "kind", raiserInt(sym.symbolKind as number));
	return raiserObject(handle);
}

// ===== nodeToValue: AST Node → RaiserValue =====
//
// MAINTENANCE: nodeToValue and readNodeFromObject (further down) are paired.
// Each NodeKind case here MUST have a matching case in readNodeFromObject that
// reads back the SAME field names. When adding/removing fields in NodeData,
// update BOTH dispatchers, or round-trip serialization will silently corrupt nodes.
//
// EXCEPTION — `nodeType` field (Day 8 SERIALIZE):
// Forward-only by design. nodeToValue emits `nodeType` (synthesized type AST)
// for macros to read. valueToNode/readNodeFromObject deliberately IGNORE the
// field — checker re-resolves types on macro output, so reverse path would be
// dead work and risk shape drift. DO NOT add a paired read.

export function nodeToValue(node: Node, objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap): RaiserValue {
	const handle = heapAllocObject(objHeap);
	// Common fields: kind, line, column
	const kindVal = raiserInt(node.kind as number);
	heapObjectSetField(objHeap, handle, "kind", kindVal);
	const lineVal = raiserInt(node.location.line);
	heapObjectSetField(objHeap, handle, "line", lineVal);
	const colVal = raiserInt(node.location.column);
	heapObjectSetField(objHeap, handle, "column", colVal);
	if (node.location.endLine > 0) {
		heapObjectSetField(objHeap, handle, "endLine", raiserInt(node.location.endLine));
		heapObjectSetField(objHeap, handle, "endColumn", raiserInt(node.location.endColumn));
	}

	match (node.kind) {
		// === Literals ===
		NodeKind.NumberLiteral => {
			const d = node.data as NumberLiteralData;
			const v = raiserFloat(d.value);
			heapObjectSetField(objHeap, handle, "value", v);
		},
		NodeKind.StringLiteral => {
			const d = node.data as StringLiteralData;
			setStr(objHeap, handle, "value", d.value);
		},
		NodeKind.BooleanLiteral => {
			const d = node.data as BooleanLiteralData;
			setBool(objHeap, handle, "boolValue", d.boolValue);
		},
		NodeKind.NullLiteral => {},
		NodeKind.BigIntLiteral => {
			const d = node.data as BigIntLiteralData;
			setStr(objHeap, handle, "bigintValue", d.bigintValue);
		},
		NodeKind.RegexLiteral => {
			const d = node.data as RegexLiteralData;
			setStr(objHeap, handle, "regexPattern", d.regexPattern);
		},

		// === Identifier ===
		NodeKind.Identifier => {
			const d = node.data as IdentifierData;
			setStr(objHeap, handle, "name", d.name);
		},

		// === Binary/Unary/Update ===
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			setStr(objHeap, handle, "operator", d.operator);
			setNode(objHeap, arrHeap, handle, "left", d.left);
			setNode(objHeap, arrHeap, handle, "right", d.right);
		},
		NodeKind.UnaryExpr => {
			const d = node.data as UnaryExprData;
			setStr(objHeap, handle, "unaryOp", d.unaryOp);
			setNode(objHeap, arrHeap, handle, "operand", d.operand);
		},
		NodeKind.UpdateExpr => {
			const d = node.data as UpdateExprData;
			setStr(objHeap, handle, "updateOp", d.updateOp);
			setNode(objHeap, arrHeap, handle, "updateArg", d.updateArg);
			setBool(objHeap, handle, "isPrefix", d.isPrefix);
		},

		// === Call/Member/Access ===
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			setNode(objHeap, arrHeap, handle, "callee", d.callee);
			setNodes(objHeap, arrHeap, handle, "arguments", d.arguments);
		},
		NodeKind.MemberExpr => {
			const d = node.data as MemberExprData;
			setNode(objHeap, arrHeap, handle, "object", d.object);
			setStr(objHeap, handle, "property", d.property);
			setBool(objHeap, handle, "isOptional", d.isOptional);
		},
		NodeKind.ArrayAccess => {
			const d = node.data as ArrayAccessData;
			setNode(objHeap, arrHeap, handle, "array", d.array);
			setNode(objHeap, arrHeap, handle, "index", d.index);
		},

		// === Collection literals ===
		NodeKind.ObjectLiteral => {
			const d = node.data as ObjectLiteralData;
			setNodes(objHeap, arrHeap, handle, "properties", d.properties);
			setStrs(objHeap, arrHeap, handle, "keys", d.keys);
		},
		NodeKind.ArrayLiteral => {
			const d = node.data as ArrayLiteralData;
			setNodes(objHeap, arrHeap, handle, "elements", d.elements);
		},

		// === Function expressions ===
		NodeKind.ArrowFunction => {
			const d = node.data as ArrowFunctionData;
			setStrs(objHeap, arrHeap, handle, "arrowParams", d.arrowParams);
			setStrs(objHeap, arrHeap, handle, "arrowParamTypes", d.arrowParamTypes);
			setNode(objHeap, arrHeap, handle, "arrowBody", d.arrowBody);
			setStr(objHeap, handle, "arrowFlags", d.arrowFlags);
			setStr(objHeap, handle, "arrowReturnType", d.arrowReturnType);
		},
		NodeKind.FunctionExpr => {
			const d = node.data as FunctionExprData;
			setStrs(objHeap, arrHeap, handle, "funcExprParams", d.funcExprParams);
			setStrs(objHeap, arrHeap, handle, "funcExprParamTypes", d.funcExprParamTypes);
			setNode(objHeap, arrHeap, handle, "funcExprBody", d.funcExprBody);
			setStr(objHeap, handle, "funcExprFlags", d.funcExprFlags);
			setStr(objHeap, handle, "funcExprReturnType", d.funcExprReturnType);
		},

		// === Other expressions ===
		NodeKind.TypeAssertion => {
			const d = node.data as TypeAssertionData;
			setNode(objHeap, arrHeap, handle, "asExpr", d.asExpr);
			setStr(objHeap, handle, "asType", d.asType);
		},
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			setNode(objHeap, arrHeap, handle, "ternaryCondition", d.ternaryCondition);
			setNode(objHeap, arrHeap, handle, "ternaryConsequent", d.ternaryConsequent);
			setNode(objHeap, arrHeap, handle, "ternaryAlternate", d.ternaryAlternate);
		},
		NodeKind.SpreadExpr => {
			const d = node.data as SpreadExprData;
			setNode(objHeap, arrHeap, handle, "spreadArg", d.spreadArg);
		},
		NodeKind.NewExpr => {
			const d = node.data as NewExprData;
			setNode(objHeap, arrHeap, handle, "newCallee", d.newCallee);
			setNodes(objHeap, arrHeap, handle, "newArguments", d.newArguments);
		},
		NodeKind.TryExpr => {
			const d = node.data as TryExprData;
			setNode(objHeap, arrHeap, handle, "tryArg", d.tryArg);
			setBool(objHeap, handle, "hasCatch", d.hasCatch);
			if (d.hasCatch) { setNode(objHeap, arrHeap, handle, "catchVal", d.catchVal); }
		},
		NodeKind.MatchExpr => {
			const d = node.data as MatchExprData;
			setNode(objHeap, arrHeap, handle, "matchDisc", d.matchDisc);
			setNodes(objHeap, arrHeap, handle, "matchCases", d.matchCases);
		},
		NodeKind.MatchCase => {
			const d = node.data as MatchCaseData;
			setNodes(objHeap, arrHeap, handle, "casePatterns", d.casePatterns);
			setNode(objHeap, arrHeap, handle, "caseGuard", d.caseGuard);
			setNode(objHeap, arrHeap, handle, "caseBody", d.caseBody);
		},
		NodeKind.AwaitExpr => {
			const d = node.data as AwaitExprData;
			setNode(objHeap, arrHeap, handle, "awaitArg", d.awaitArg);
		},
		NodeKind.YieldExpr => {
			const d = node.data as YieldExprData;
			setNode(objHeap, arrHeap, handle, "yieldArg", d.yieldArg);
			setBool(objHeap, handle, "isDelegate", d.isDelegate);
		},
		NodeKind.MoveExpr => {
			const d = node.data as MoveExprData;
			setNode(objHeap, arrHeap, handle, "moveArg", d.moveArg);
		},
		NodeKind.OutExpr => {
			const d = node.data as OutExprData;
			setNode(objHeap, arrHeap, handle, "outArg", d.outArg);
		},
		NodeKind.SizeofExpr => {
			const d = node.data as SizeofExprData;
			setStr(objHeap, handle, "sizeofType", d.sizeofType);
		},
		NodeKind.HiddenDeref => {
			const d = node.data as HiddenDerefData;
			setNode(objHeap, arrHeap, handle, "expr", d.expr);
		},
		NodeKind.QuoteExpr => {
			const d = node.data as QuoteExprData;
			setNode(objHeap, arrHeap, handle, "quoteBody", d.quoteBody);
		},
		NodeKind.ComptimeBlock => {
			const d = node.data as ComptimeBlockData;
			setNode(objHeap, arrHeap, handle, "comptimeBody", d.comptimeBody);
		},
		NodeKind.TypeAnnotation => {
			const d = node.data as TypeAnnotationData;
			setStr(objHeap, handle, "annotationType", d.annotationType);
		},

		// === Patterns ===
		NodeKind.ArrayPattern => {
			const d = node.data as ArrayPatternData;
			setNodes(objHeap, arrHeap, handle, "patternElements", d.patternElements);
			setBool(objHeap, handle, "hasRestElement", d.hasRestElement);
		},
		NodeKind.ObjectPattern => {
			const d = node.data as ObjectPatternData;
			setNodes(objHeap, arrHeap, handle, "patternProps", d.patternProps);
			setBool(objHeap, handle, "hasRestProp", d.hasRestProp);
		},
		NodeKind.ObjectPatternProp => {
			const d = node.data as ObjectPatternPropData;
			setStr(objHeap, handle, "propKey", d.propKey);
			setNode(objHeap, arrHeap, handle, "propAlias", d.propAlias);
		},
		NodeKind.DestructuringDecl => {
			const d = node.data as DestructuringDeclData;
			setNode(objHeap, arrHeap, handle, "destrPattern", d.destrPattern);
			setNode(objHeap, arrHeap, handle, "destrInit", d.destrInit);
			setBool(objHeap, handle, "destrIsConst", d.destrIsConst);
		},

		// === Statements ===
		NodeKind.ExprStmt => {
			const d = node.data as ExprStmtData;
			setNode(objHeap, arrHeap, handle, "expr", d.expr);
		},
		NodeKind.ReturnStmt => {
			const d = node.data as ReturnStmtData;
			setNode(objHeap, arrHeap, handle, "argument", d.argument);
		},
		NodeKind.ThrowStmt => {
			const d = node.data as ThrowStmtData;
			setNode(objHeap, arrHeap, handle, "throwArg", d.throwArg);
		},
		NodeKind.DeferStmt => {
			const d = node.data as DeferStmtData;
			setNode(objHeap, arrHeap, handle, "deferExpr", d.deferExpr);
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			setNodes(objHeap, arrHeap, handle, "statements", d.statements);
		},
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			setStr(objHeap, handle, "declName", d.declName);
			setStr(objHeap, handle, "declType", d.declType);
			setNode(objHeap, arrHeap, handle, "initializer", d.initializer);
			const dk = raiserInt(d.declKind as number);
			heapObjectSetField(objHeap, handle, "declKind", dk);
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			setNode(objHeap, arrHeap, handle, "condition", d.condition);
			setNode(objHeap, arrHeap, handle, "consequent", d.consequent);
			setNode(objHeap, arrHeap, handle, "alternate", d.alternate);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			setNode(objHeap, arrHeap, handle, "whileCondition", d.whileCondition);
			setNode(objHeap, arrHeap, handle, "whileBody", d.whileBody);
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			setNode(objHeap, arrHeap, handle, "doBody", d.doBody);
			setNode(objHeap, arrHeap, handle, "doCondition", d.doCondition);
		},
		NodeKind.ForStmt => {
			const d = node.data as ForStmtData;
			setNode(objHeap, arrHeap, handle, "forInit", d.forInit);
			setNode(objHeap, arrHeap, handle, "forCondition", d.forCondition);
			setNode(objHeap, arrHeap, handle, "forUpdate", d.forUpdate);
			setNode(objHeap, arrHeap, handle, "forBody", d.forBody);
		},
		NodeKind.ForOfStmt => {
			const d = node.data as ForOfStmtData;
			setStr(objHeap, handle, "forOfBinding", d.forOfBinding);
			setBool(objHeap, handle, "forOfIsConst", d.forOfIsConst);
			setNode(objHeap, arrHeap, handle, "forOfIterable", d.forOfIterable);
			setNode(objHeap, arrHeap, handle, "forOfBody", d.forOfBody);
		},
		NodeKind.ForInStmt => {
			const d = node.data as ForInStmtData;
			setStr(objHeap, handle, "forInBinding", d.forInBinding);
			setBool(objHeap, handle, "forInIsConst", d.forInIsConst);
			setNode(objHeap, arrHeap, handle, "forInObject", d.forInObject);
			setNode(objHeap, arrHeap, handle, "forInBody", d.forInBody);
		},
		NodeKind.BreakStmt => {
			const d = node.data as BreakStmtData;
			setStr(objHeap, handle, "breakLabel", d.breakLabel);
		},
		NodeKind.ContinueStmt => {
			const d = node.data as ContinueStmtData;
			setStr(objHeap, handle, "continueLabel", d.continueLabel);
		},
		NodeKind.UnreachableStmt => {
			const d = node.data as UnreachableStmtData;
			setStr(objHeap, handle, "unreachableMsg", d.unreachableMsg);
		},
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			setNode(objHeap, arrHeap, handle, "switchDisc", d.switchDisc);
			setNodes(objHeap, arrHeap, handle, "switchCases", d.switchCases);
		},
		NodeKind.SwitchCase => {
			const d = node.data as SwitchCaseData;
			setNodes(objHeap, arrHeap, handle, "caseTests", d.caseTests);
			setNodes(objHeap, arrHeap, handle, "caseStmts", d.caseStmts);
			setBool(objHeap, handle, "isDefault", d.isDefault);
		},
		NodeKind.MatchStmt => {
			const d = node.data as MatchStmtData;
			setNode(objHeap, arrHeap, handle, "matchStmtDisc", d.matchStmtDisc);
			setNodes(objHeap, arrHeap, handle, "matchStmtCases", d.matchStmtCases);
		},
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			setNode(objHeap, arrHeap, handle, "tryBody", d.tryBody);
			setStr(objHeap, handle, "catchName", d.catchName);
			setNode(objHeap, arrHeap, handle, "catchBody", d.catchBody);
			setNode(objHeap, arrHeap, handle, "finallyBody", d.finallyBody);
		},

		// === Declarations ===
		NodeKind.FunctionDecl => {
			const d = node.data as FunctionDeclData;
			setStr(objHeap, handle, "fnName", d.fnName);
			setStrs(objHeap, arrHeap, handle, "params", d.params);
			setStrs(objHeap, arrHeap, handle, "fnParamTypes", d.fnParamTypes);
			setNode(objHeap, arrHeap, handle, "fnBody", d.fnBody);
			setStr(objHeap, handle, "fnFlags", d.fnFlags);
			setStr(objHeap, handle, "fnReturnType", d.fnReturnType);
		},
		NodeKind.ImportDecl => {
			const d = node.data as ImportDeclData;
			setStrs(objHeap, arrHeap, handle, "importNames", d.importNames);
			setStrs(objHeap, arrHeap, handle, "importAliases", d.importAliases);
			setStr(objHeap, handle, "importSource", d.importSource);
		},
		NodeKind.ExportDecl => {
			const d = node.data as ExportDeclData;
			setNode(objHeap, arrHeap, handle, "exportedDecl", d.exportedDecl);
		},
		NodeKind.TypeAliasDecl => {
			const d = node.data as TypeAliasDeclData;
			setStr(objHeap, handle, "aliasName", d.aliasName);
			setStr(objHeap, handle, "aliasType", d.aliasType);
			setBool(objHeap, handle, "aliasIsDistinct", d.aliasIsDistinct);
		},
		NodeKind.EnumDecl => {
			const d = node.data as EnumDeclData;
			setStr(objHeap, handle, "enumName", d.enumName);
			setStrs(objHeap, arrHeap, handle, "enumMembers", d.enumMembers);
		},
		NodeKind.InterfaceDecl | NodeKind.StructDecl => {
			const d = node.data as InterfaceDeclData;
			setStr(objHeap, handle, "interfaceName", d.interfaceName);
			setStrs(objHeap, arrHeap, handle, "interfaceFields", d.interfaceFields);
			setStrs(objHeap, arrHeap, handle, "interfaceFieldTypes", d.interfaceFieldTypes);
		},
		NodeKind.ClassDecl => {
			const d = node.data as ClassDeclData;
			setStr(objHeap, handle, "className", d.className);
			setStr(objHeap, handle, "classExtends", d.classExtends);
			setNodes(objHeap, arrHeap, handle, "classBody", d.classBody);
		},
		NodeKind.ActorDecl => {
			const d = node.data as ActorDeclData;
			setStr(objHeap, handle, "actorName", d.actorName);
			setNodes(objHeap, arrHeap, handle, "actorBody", d.actorBody);
		},
		NodeKind.PropertyDecl => {
			const d = node.data as PropertyDeclData;
			setStr(objHeap, handle, "propName", d.propName);
			setStr(objHeap, handle, "propType", d.propType);
			setBool(objHeap, handle, "propIsStatic", d.propIsStatic);
		},
		NodeKind.MethodDecl => {
			const d = node.data as MethodDeclData;
			setStr(objHeap, handle, "methodName", d.methodName);
			setStrs(objHeap, arrHeap, handle, "methodParams", d.methodParams);
			setStrs(objHeap, arrHeap, handle, "methodParamTypes", d.methodParamTypes);
			setNode(objHeap, arrHeap, handle, "methodBody", d.methodBody);
			setBool(objHeap, handle, "methodIsStatic", d.methodIsStatic);
			setStr(objHeap, handle, "methodFlags", d.methodFlags);
			setStr(objHeap, handle, "methodReturnType", d.methodReturnType);
		},
		NodeKind.ConstructorDecl => {
			const d = node.data as ConstructorDeclData;
			setStrs(objHeap, arrHeap, handle, "ctorParams", d.ctorParams);
			setStrs(objHeap, arrHeap, handle, "ctorParamTypes", d.ctorParamTypes);
			setNode(objHeap, arrHeap, handle, "ctorBody", d.ctorBody);
		},
		NodeKind.ExternDecl => {
			const d = node.data as ExternDeclData;
			heapObjectSetField(objHeap, handle, "externKind", raiserInt(d.externKind as number));
			setStr(objHeap, handle, "externName", d.externName);
			setStr(objHeap, handle, "nativeName", d.nativeName);
			setStr(objHeap, handle, "externType", d.externType);
		},
		NodeKind.MacroDecl => {
			const d = node.data as MacroDeclData;
			setStr(objHeap, handle, "macroDeclName", d.macroDeclName);
			setStrs(objHeap, arrHeap, handle, "macroDeclParams", d.macroDeclParams);
			setStrs(objHeap, arrHeap, handle, "macroDeclParamTypes", d.macroDeclParamTypes);
			setNode(objHeap, arrHeap, handle, "macroDeclBody", d.macroDeclBody);
		},
		NodeKind.DecoratedDecl => {
			const d = node.data as DecoratedDeclData;
			setNodes(objHeap, arrHeap, handle, "decorators", d.decorators);
			setNode(objHeap, arrHeap, handle, "decoratedNode", d.decoratedNode);
		},
		NodeKind.MacroInvocation => {
			const d = node.data as MacroInvocationData;
			setStr(objHeap, handle, "macroName", d.macroName);
			setNodes(objHeap, arrHeap, handle, "macroArgs", d.macroArgs);
		},

		// === Testing ===
		NodeKind.TestDecl => {
			const d = node.data as TestDeclData;
			setStr(objHeap, handle, "testName", d.testName);
			setNode(objHeap, arrHeap, handle, "testBody", d.testBody);
		},
		NodeKind.AssertStmt => {
			const d = node.data as AssertStmtData;
			setNode(objHeap, arrHeap, handle, "assertExpr", d.assertExpr);
			setStr(objHeap, handle, "assertSource", d.assertSource);
			setStr(objHeap, handle, "assertMessage", d.assertMessage);
		},

		// === Program ===
		NodeKind.Program => {
			const d = node.data as ProgramData;
			setNodes(objHeap, arrHeap, handle, "programStmts", d.programStmts);
		},

		// === SpliceMany — A2 macro multi-decl emission ===
		NodeKind.SpliceMany => {
			const d = node.data as SpliceManyData;
			setNodes(objHeap, arrHeap, handle, "spliceNodes", d.spliceNodes);
		},

		// === Type AST nodes (synthesized by mapTypeToAst, Day 8) ===
		// NOTE: macros do NOT consume these directly via nodeToValue — the
		// production macro path is `nodeToASTLiteral` in expand.ms (source-form
		// inlining). These cases serve unit-test coverage of the heap path and
		// keep nodeToValue complete for future heap-based consumers. When adding
		// new type-AST kinds, ALSO update `addKindFields` in expand.ms.
		NodeKind.TypeObject => {
			const d = node.data as TypeObjectData;
			setStrs(objHeap, arrHeap, handle, "typExprFieldNames", d.typExprFieldNames);
			setNodes(objHeap, arrHeap, handle, "typExprFieldTypes", d.typExprFieldTypes);
			setNode(objHeap, arrHeap, handle, "typExprIndexKey", d.typExprIndexKey);
			setNode(objHeap, arrHeap, handle, "typExprIndexValue", d.typExprIndexValue);
			setNodeArrays(objHeap, arrHeap, handle, "typExprFieldDecorators", d.typExprFieldDecorators);
			setStr(objHeap, handle, "typExprTypeName", d.typExprTypeName);
		},
		NodeKind.TypeArray => {
			const d = node.data as TypeArrayData;
			setNode(objHeap, arrHeap, handle, "typExprElement", d.typExprElement);
			heapObjectSetField(objHeap, handle, "typExprSize", raiserInt(d.typExprSize));
		},
		NodeKind.TypeUnion => {
			// V3 disc fields — symmetric with deserialize in this file
			// + macro VM access path in src/compiler/meta/expand.ms.
			// Update all 3 sites together when adding fields.
			const d = node.data as TypeUnionData;
			setNodes(objHeap, arrHeap, handle, "typExprMembers", d.typExprMembers);
			setStr(objHeap, handle, "discFieldName", d.discFieldName);
			setStrs(objHeap, arrHeap, handle, "variantKeys", d.variantKeys);
			setStr(objHeap, handle, "discKind", d.discKind);
		},
		NodeKind.TypeIntersection => {
			const d = node.data as TypeIntersectionData;
			setNodes(objHeap, arrHeap, handle, "typExprMembers", d.typExprMembers);
		},
		NodeKind.TypeGeneric => {

			const d = node.data as TypeGenericData;
			setNode(objHeap, arrHeap, handle, "typExprBase", d.typExprBase);
			setNodes(objHeap, arrHeap, handle, "typExprArgs", d.typExprArgs);
		},
		NodeKind.TypeFunction => {
			const d = node.data as TypeFunctionData;
			setNodes(objHeap, arrHeap, handle, "typExprParams", d.typExprParams);
			setNode(objHeap, arrHeap, handle, "typExprReturn", d.typExprReturn);
			setStrs(objHeap, arrHeap, handle, "typExprParamNames", d.typExprParamNames);
		},

		// === JSX (compile-time only — serialized for macro VM round-trip) ===
		NodeKind.JSXElement => {
			const d = node.data as JSXElementData;
			setStr(objHeap, handle, "jsxTag", d.jsxTag);
			setNodes(objHeap, arrHeap, handle, "jsxAttrs", d.jsxAttrs);
			setNodes(objHeap, arrHeap, handle, "jsxChildren", d.jsxChildren);
			setBool(objHeap, handle, "jsxSelfClosing", d.jsxSelfClosing);
		},
		NodeKind.JSXFragment => {
			const d = node.data as JSXFragmentData;
			setNodes(objHeap, arrHeap, handle, "jsxFragChildren", d.jsxFragChildren);
		},
		NodeKind.JSXText => {
			const d = node.data as JSXTextData;
			setStr(objHeap, handle, "jsxText", d.jsxText);
		},
		NodeKind.JSXExpressionContainer => {
			const d = node.data as JSXExpressionContainerData;
			setNode(objHeap, arrHeap, handle, "jsxExpr", d.jsxExpr);
		},
		NodeKind.JSXAttribute => {
			const d = node.data as JSXAttributeData;
			setStr(objHeap, handle, "jsxAttrName", d.jsxAttrName);
			setNode(objHeap, arrHeap, handle, "jsxAttrValue", d.jsxAttrValue);
		},
		NodeKind.JSXSpreadAttribute => {
			const d = node.data as JSXSpreadAttributeData;
			setNode(objHeap, arrHeap, handle, "jsxSpreadArg", d.jsxSpreadArg);
		},

		// Any unrecognized kind: kind/line/column only
		_ => {},
	};

	// Day 8: emit `nodeType` field for nodes that have resolved type info.
	// mapTypeToAst produces a synthesized Node tree (Identifier/TypeObject/etc.);
	// nodeToValue recurses to serialize it. Synthesized nodes have
	// `nodeType === null` (set by createNode in std/meta/node.ms:566), so the
	// recursion terminates exactly one level deep.
	//
	// Forward-only: macros READ value.nodeType. Reverse path (valueToNode) ignores
	// nodeType — checker re-resolves types on macro output, so round-trip
	// asymmetry is intentional.
	if (node.nodeType !== null) {
		const typeAst = mapTypeToAst(node.nodeType, node.location);
		setNode(objHeap, arrHeap, handle, "nodeType", typeAst);
	}

	// Day 9: emit `resolvedSym` for nodes the checker bound to a Symbol.
	// Surfaces { name, kind } only — `declNode` is intentionally skipped to avoid
	// Symbol ↔ Node cycle (declNode is a Node whose resolvedSym points back).
	// V2 can lift this if codecs need the declaration site; for now, macros that
	// need it can re-resolve via the parent module.
	//
	// Forward-only like nodeType. valueToNode ignores `resolvedSym`.
	if (node.resolvedSym !== null) {
		heapObjectSetField(objHeap, handle, "resolvedSym", symbolToValue(node.resolvedSym, objHeap));
	}

	return raiserObject(handle);
}

// ===== Deserialization helpers (read from RaiserValue) =====

function readStr(objHeap: RaiserObjectHeap, h: number, name: string): string {
	const v = heapObjectGetField(objHeap, h, name);
	if (v.kind === RaiserValueKind.String) return v.strVal;
	return "";
}

function readInt(objHeap: RaiserObjectHeap, h: number, name: string): number {
	const v = heapObjectGetField(objHeap, h, name);
	return match (v.kind) {
		RaiserValueKind.Int | RaiserValueKind.Bool => v.intVal,
		RaiserValueKind.Float => v.floatVal,
		_ => 0,
	};
}

function readFloat(objHeap: RaiserObjectHeap, h: number, name: string): number {
	const v = heapObjectGetField(objHeap, h, name);
	if (v.kind === RaiserValueKind.Float) return v.floatVal;
	if (v.kind === RaiserValueKind.Int) return v.intVal + 0.0;
	return 0.0;
}

function readBool(objHeap: RaiserObjectHeap, h: number, name: string): boolean {
	// Accept both Bool kind and Int kind (0/1) as boolean — aligns with
	// the project convention used by unboxBool (raiser/marshal.ms:50),
	// truthiness check (raiser/value.ms:80), and readInt (this file:1023+).
	// Comparison codegen currently emits raiserInt(0/1) for boolean results,
	// so without this leniency, BooleanLiteral fields stored from comparison
	// expressions silently default to false. See bug026.
	const v = heapObjectGetField(objHeap, h, name);
	if (v.kind === RaiserValueKind.Bool || v.kind === RaiserValueKind.Int) return v.intVal !== 0;
	return false;
}

function readNode(objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap, h: number, name: string, fallbackLoc: SourceLocation): Node {
	const v = heapObjectGetField(objHeap, h, name);
	if (v.kind === RaiserValueKind.Nil) return null as unknown as Node;
	return valueToNode(v, objHeap, arrHeap, fallbackLoc);
}

function readNodes(objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap, h: number, name: string, fallbackLoc: SourceLocation): Node[] {
	const v = heapObjectGetField(objHeap, h, name);
	const result: Node[] = [];
	if (v.kind !== RaiserValueKind.Array) return result;
	const handle = v.intVal;
	const len = heapArrayLen(arrHeap, handle);
	let i = 0;
	while (i < len) {
		const elem = heapArrayGet(arrHeap, handle, i);
		result.push(valueToNode(elem, objHeap, arrHeap, fallbackLoc));
		i = i + 1;
	}
	return result;
}

function readStrs(objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap, h: number, name: string): string[] {
	const v = heapObjectGetField(objHeap, h, name);
	const result: string[] = [];
	if (v.kind !== RaiserValueKind.Array) return result;
	const handle = v.intVal;
	const len = heapArrayLen(arrHeap, handle);
	let i = 0;
	while (i < len) {
		const elem = heapArrayGet(arrHeap, handle, i);
		if (elem.kind === RaiserValueKind.String) {
			result.push(elem.strVal);
		} else {
			result.push("");
		}
		i = i + 1;
	}
	return result;
}

function readLoc(objHeap: RaiserObjectHeap, h: number): SourceLocation {
	const loc = makeLoc(readInt(objHeap, h, "line"), readInt(objHeap, h, "column"));
	const el = readInt(objHeap, h, "endLine");
	if (el > 0) {
		loc.endLine = el as int32;
		loc.endColumn = readInt(objHeap, h, "endColumn") as int32;
	}
	return loc;
}

// ===== valueToNode: RaiserValue → AST Node =====

export function valueToNode(val: RaiserValue, objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap, fallbackLoc: SourceLocation): Node {
	return match (val.kind) {
		RaiserValueKind.Int => mkNumber(val.intVal, fallbackLoc),
		RaiserValueKind.Float => mkNumber(val.floatVal, fallbackLoc),
		RaiserValueKind.Bool => mkBool(val.intVal !== 0, fallbackLoc),
		RaiserValueKind.String => mkString(val.strVal, fallbackLoc),
		RaiserValueKind.Nil => mkNull(fallbackLoc),
		RaiserValueKind.Array => {
			const handle = val.intVal;
			const len = heapArrayLen(arrHeap, handle);
			const elements: Node[] = [];
			let i = 0;
			while (i < len) {
				const elem = heapArrayGet(arrHeap, handle, i);
				elements.push(valueToNode(elem, objHeap, arrHeap, fallbackLoc));
				i = i + 1;
			}
			return createNodeAt(NodeKind.ArrayLiteral, { elements }, fallbackLoc);
		},
		RaiserValueKind.Object => {
			const handle = val.intVal;
			// Check for "kind" field — if present, this is a serialized Node
			const kindField = heapObjectGetField(objHeap, handle, "kind");
			if (kindField.kind === RaiserValueKind.Int) {
				const out = readNodeFromObject(handle, kindField.intVal as NodeKind, objHeap, arrHeap, fallbackLoc);
				// Preserve type-AST hint so subsequent macro expansions see the
				// original arg's type info (Node.nodeType is a Type and can't
				// be round-tripped; the type-AST Node form survives via
				// nodeTypeAst). Fixes Bug 6 nested-macro re-expansion path.
				if (out !== null) {
					const ntField = heapObjectGetField(objHeap, handle, "nodeType");
					if (ntField.kind === RaiserValueKind.Object) {
						out.nodeTypeAst = valueToNode(ntField, objHeap, arrHeap, fallbackLoc);
					}
				}
				return out;
			}
			// No "kind" field — fall back to ObjectLiteral
			return deserializeObjectLiteral(handle, objHeap, arrHeap, fallbackLoc);
		},
		_ => mkNull(fallbackLoc),
	};
}

function deserializeObjectLiteral(handle: number, objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap, loc: SourceLocation): Node {
	const obj = objHeap.objects[handle];
	const keys: string[] = [];
	const values: Node[] = [];
	for (const field of obj.fields) {
		keys.push(field.name);
		values.push(valueToNode(field.value, objHeap, arrHeap, loc));
	}
	return createNodeAt(NodeKind.ObjectLiteral, { properties: values, keys, keyLocations: [] }, loc);
}

// Reconstruct a Node from a serialized heap object.
// MAINTENANCE: This is the exact mirror of nodeToValue above. Field names MUST match.
// When you add a field to nodeToValue, add the corresponding read here.
function readNodeFromObject(h: number, kind: NodeKind, objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap, fallbackLoc: SourceLocation): Node {
	const loc = readLoc(objHeap, h);
	return match (kind) {
		// === Literals ===
		NodeKind.NumberLiteral => {
			const value = readFloat(objHeap, h, "value");
			return createNodeAt(NodeKind.NumberLiteral, { value, isFloat: value % 1 !== 0 }, loc);
		},
		NodeKind.StringLiteral => {
			return createNodeAt(NodeKind.StringLiteral, { value: readStr(objHeap, h, "value") }, loc);
		},
		NodeKind.BooleanLiteral => {
			return createNodeAt(NodeKind.BooleanLiteral, { boolValue: readBool(objHeap, h, "boolValue") }, loc);
		},
		NodeKind.NullLiteral => {
			return createNodeAt(NodeKind.NullLiteral, { nullPlaceholder: true }, loc);
		},
		NodeKind.BigIntLiteral => {
			return createNodeAt(NodeKind.BigIntLiteral, { bigintValue: readStr(objHeap, h, "bigintValue") }, loc);
		},
		NodeKind.RegexLiteral => {
			return createNodeAt(NodeKind.RegexLiteral, { regexPattern: readStr(objHeap, h, "regexPattern") }, loc);
		},

		// === Identifier ===
		NodeKind.Identifier => {
			return createNodeAt(NodeKind.Identifier, { name: readStr(objHeap, h, "name") }, loc);
		},

		// === Binary/Unary/Update ===
		NodeKind.BinaryExpr => {
			const operator = readStr(objHeap, h, "operator");
			const left = readNode(objHeap, arrHeap, h, "left", loc);
			const right = readNode(objHeap, arrHeap, h, "right", loc);
			return createNodeAt(NodeKind.BinaryExpr, { operator, left, right }, loc);
		},
		NodeKind.UnaryExpr => {
			const unaryOp = readStr(objHeap, h, "unaryOp");
			const operand = readNode(objHeap, arrHeap, h, "operand", loc);
			return createNodeAt(NodeKind.UnaryExpr, { unaryOp, operand }, loc);
		},
		NodeKind.UpdateExpr => {
			const updateOp = readStr(objHeap, h, "updateOp");
			const updateArg = readNode(objHeap, arrHeap, h, "updateArg", loc);
			const isPrefix = readBool(objHeap, h, "isPrefix");
			return createNodeAt(NodeKind.UpdateExpr, { updateOp, updateArg, isPrefix }, loc);
		},

		// === Call/Member/Access ===
		NodeKind.CallExpr => {
			const callee = readNode(objHeap, arrHeap, h, "callee", loc);
			const args = readNodes(objHeap, arrHeap, h, "arguments", loc);
			return createNodeAt(NodeKind.CallExpr, {
				callee, arguments: args, isDirectCall: true, resolvedOverloadIdx: 0,
			}, loc);
		},
		NodeKind.MemberExpr => {
			const object = readNode(objHeap, arrHeap, h, "object", loc);
			const property = readStr(objHeap, h, "property");
			const isOptional = readBool(objHeap, h, "isOptional");
			return createNodeAt(NodeKind.MemberExpr, { object, property, isOptional }, loc);
		},
		NodeKind.ArrayAccess => {
			const array = readNode(objHeap, arrHeap, h, "array", loc);
			const index = readNode(objHeap, arrHeap, h, "index", loc);
			return createNodeAt(NodeKind.ArrayAccess, { array, index }, loc);
		},

		// === Collection literals ===
		NodeKind.ObjectLiteral => {
			const properties = readNodes(objHeap, arrHeap, h, "properties", loc);
			const keys = readStrs(objHeap, arrHeap, h, "keys");
			return createNodeAt(NodeKind.ObjectLiteral, { properties, keys, keyLocations: [] }, loc);
		},
		NodeKind.ArrayLiteral => {
			const elements = readNodes(objHeap, arrHeap, h, "elements", loc);
			return createNodeAt(NodeKind.ArrayLiteral, { elements }, loc);
		},

		// === Function expressions ===
		NodeKind.ArrowFunction => {
			const arrowParams = readStrs(objHeap, arrHeap, h, "arrowParams");
			const arrowParamTypes = readStrs(objHeap, arrHeap, h, "arrowParamTypes");
			const arrowBody = readNode(objHeap, arrHeap, h, "arrowBody", loc);
			const arrowFlags = readStr(objHeap, h, "arrowFlags");
			const arrowReturnType = readStr(objHeap, h, "arrowReturnType");
			// Invariant: arrowDefaults.length === arrowParams.length. Macros emitting
			// arrows can't (yet) carry defaults through serialization; pad with null
			// per param to maintain the invariant for downstream consumers.
			const arrowDefaults: (Node | null)[] = [];
			let dpi = 0;
			while (dpi < arrowParams.length) {
				arrowDefaults.push(null);
				dpi = dpi + 1;
			}
			return createNodeAt(NodeKind.ArrowFunction, {
				arrowParams, arrowParamTypes, arrowBody, arrowFlags, arrowReturnType,
				arrowDefaults,
			}, loc);
		},
		NodeKind.FunctionExpr => {
			const funcExprParams = readStrs(objHeap, arrHeap, h, "funcExprParams");
			const funcExprParamTypes = readStrs(objHeap, arrHeap, h, "funcExprParamTypes");
			const funcExprBody = readNode(objHeap, arrHeap, h, "funcExprBody", loc);
			const funcExprFlags = readStr(objHeap, h, "funcExprFlags");
			const funcExprReturnType = readStr(objHeap, h, "funcExprReturnType");
			return createNodeAt(NodeKind.FunctionExpr, {
				funcExprParams, funcExprParamTypes, funcExprBody, funcExprFlags, funcExprReturnType,
			}, loc);
		},

		// === Other expressions ===
		NodeKind.TypeAssertion => {
			const asExpr = readNode(objHeap, arrHeap, h, "asExpr", loc);
			const asType = readStr(objHeap, h, "asType");
			return createNodeAt(NodeKind.TypeAssertion, { asExpr, asType }, loc);
		},
		NodeKind.ConditionalExpr => {
			const ternaryCondition = readNode(objHeap, arrHeap, h, "ternaryCondition", loc);
			const ternaryConsequent = readNode(objHeap, arrHeap, h, "ternaryConsequent", loc);
			const ternaryAlternate = readNode(objHeap, arrHeap, h, "ternaryAlternate", loc);
			return createNodeAt(NodeKind.ConditionalExpr, {
				ternaryCondition, ternaryConsequent, ternaryAlternate,
			}, loc);
		},
		NodeKind.SpreadExpr => {
			const spreadArg = readNode(objHeap, arrHeap, h, "spreadArg", loc);
			return createNodeAt(NodeKind.SpreadExpr, { spreadArg }, loc);
		},
		NodeKind.NewExpr => {
			const newCallee = readNode(objHeap, arrHeap, h, "newCallee", loc);
			const newArguments = readNodes(objHeap, arrHeap, h, "newArguments", loc);
			return createNodeAt(NodeKind.NewExpr, { newCallee, newArguments }, loc);
		},
		NodeKind.TryExpr => {
			const tryArg = readNode(objHeap, arrHeap, h, "tryArg", loc);
			const hasCatch = readBool(objHeap, h, "hasCatch");
			const catchVal = hasCatch ? readNode(objHeap, arrHeap, h, "catchVal", loc) : (null as unknown as Node);
			return createNodeAt(NodeKind.TryExpr, { tryArg, hasCatch, catchVal }, loc);
		},
		NodeKind.MatchExpr => {
			const matchDisc = readNode(objHeap, arrHeap, h, "matchDisc", loc);
			const matchCases = readNodes(objHeap, arrHeap, h, "matchCases", loc);
			return createNodeAt(NodeKind.MatchExpr, { matchDisc, matchCases }, loc);
		},
		NodeKind.MatchCase => {
			const casePatterns = readNodes(objHeap, arrHeap, h, "casePatterns", loc);
			const caseGuard = readNode(objHeap, arrHeap, h, "caseGuard", loc);
			const caseBody = readNode(objHeap, arrHeap, h, "caseBody", loc);
			return createNodeAt(NodeKind.MatchCase, {
				casePatterns, caseGuard, caseBody,
			}, loc);
		},
		NodeKind.AwaitExpr => {
			const awaitArg = readNode(objHeap, arrHeap, h, "awaitArg", loc);
			return createNodeAt(NodeKind.AwaitExpr, { awaitArg }, loc);
		},
		NodeKind.YieldExpr => {
			const yieldArg = readNode(objHeap, arrHeap, h, "yieldArg", loc);
			const isDelegate = readBool(objHeap, h, "isDelegate");
			return createNodeAt(NodeKind.YieldExpr, { yieldArg, isDelegate }, loc);
		},
		NodeKind.MoveExpr => {
			const moveArg = readNode(objHeap, arrHeap, h, "moveArg", loc);
			return createNodeAt(NodeKind.MoveExpr, { moveArg }, loc);
		},
		NodeKind.OutExpr => {
			const outArg = readNode(objHeap, arrHeap, h, "outArg", loc);
			return createNodeAt(NodeKind.OutExpr, { outArg }, loc);
		},
		NodeKind.SizeofExpr => {
			return createNodeAt(NodeKind.SizeofExpr, { sizeofType: readStr(objHeap, h, "sizeofType") }, loc);
		},
		NodeKind.HiddenDeref => {
			const expr = readNode(objHeap, arrHeap, h, "expr", loc);
			return createNodeAt(NodeKind.HiddenDeref, { expr }, loc);
		},
		NodeKind.QuoteExpr => {
			const quoteBody = readNode(objHeap, arrHeap, h, "quoteBody", loc);
			return createNodeAt(NodeKind.QuoteExpr, { quoteBody }, loc);
		},
		NodeKind.ComptimeBlock => {
			const comptimeBody = readNode(objHeap, arrHeap, h, "comptimeBody", loc);
			return createNodeAt(NodeKind.ComptimeBlock, { comptimeBody }, loc);
		},
		NodeKind.TypeAnnotation => {
			return createNodeAt(NodeKind.TypeAnnotation, { annotationType: readStr(objHeap, h, "annotationType") }, loc);
		},

		// === Patterns ===
		NodeKind.ArrayPattern => {
			const patternElements = readNodes(objHeap, arrHeap, h, "patternElements", loc);
			const hasRestElement = readBool(objHeap, h, "hasRestElement");
			return createNodeAt(NodeKind.ArrayPattern, { patternElements, hasRestElement }, loc);
		},
		NodeKind.ObjectPattern => {
			const patternProps = readNodes(objHeap, arrHeap, h, "patternProps", loc);
			const hasRestProp = readBool(objHeap, h, "hasRestProp");
			return createNodeAt(NodeKind.ObjectPattern, { patternProps, hasRestProp }, loc);
		},
		NodeKind.ObjectPatternProp => {
			const propKey = readStr(objHeap, h, "propKey");
			const propAlias = readNode(objHeap, arrHeap, h, "propAlias", loc);
			return createNodeAt(NodeKind.ObjectPatternProp, { propKey, propAlias }, loc);
		},
		NodeKind.DestructuringDecl => {
			const destrPattern = readNode(objHeap, arrHeap, h, "destrPattern", loc);
			const destrInit = readNode(objHeap, arrHeap, h, "destrInit", loc);
			const destrIsConst = readBool(objHeap, h, "destrIsConst");
			return createNodeAt(NodeKind.DestructuringDecl, { destrPattern, destrInit, destrIsConst }, loc);
		},

		// === Statements ===
		NodeKind.ExprStmt => {
			const expr = readNode(objHeap, arrHeap, h, "expr", loc);
			return createNodeAt(NodeKind.ExprStmt, { expr }, loc);
		},
		NodeKind.ReturnStmt => {
			const argument = readNode(objHeap, arrHeap, h, "argument", loc);
			return createNodeAt(NodeKind.ReturnStmt, { argument }, loc);
		},
		NodeKind.ThrowStmt => {
			const throwArg = readNode(objHeap, arrHeap, h, "throwArg", loc);
			return createNodeAt(NodeKind.ThrowStmt, { throwArg }, loc);
		},
		NodeKind.DeferStmt => {
			const deferExpr = readNode(objHeap, arrHeap, h, "deferExpr", loc);
			return createNodeAt(NodeKind.DeferStmt, { deferExpr }, loc);
		},
		NodeKind.BlockStmt => {
			const statements = readNodes(objHeap, arrHeap, h, "statements", loc);
			return createNodeAt(NodeKind.BlockStmt, { statements }, loc);
		},
		NodeKind.VariableDecl => {
			const declName = readStr(objHeap, h, "declName");
			const declType = readStr(objHeap, h, "declType");
			const initializer = readNode(objHeap, arrHeap, h, "initializer", loc);
			const declKind = readInt(objHeap, h, "declKind") as DeclKind;
			return createNodeAt(NodeKind.VariableDecl, {
				declName, declType, initializer, declKind, nameLocation: loc,
			}, loc);
		},
		NodeKind.IfStmt => {
			const condition = readNode(objHeap, arrHeap, h, "condition", loc);
			const consequent = readNode(objHeap, arrHeap, h, "consequent", loc);
			const alternate = readNode(objHeap, arrHeap, h, "alternate", loc);
			return createNodeAt(NodeKind.IfStmt, { condition, consequent, alternate }, loc);
		},
		NodeKind.WhileStmt => {
			const whileCondition = readNode(objHeap, arrHeap, h, "whileCondition", loc);
			const whileBody = readNode(objHeap, arrHeap, h, "whileBody", loc);
			return createNodeAt(NodeKind.WhileStmt, { whileCondition, whileBody }, loc);
		},
		NodeKind.DoWhileStmt => {
			const doBody = readNode(objHeap, arrHeap, h, "doBody", loc);
			const doCondition = readNode(objHeap, arrHeap, h, "doCondition", loc);
			return createNodeAt(NodeKind.DoWhileStmt, { doBody, doCondition }, loc);
		},
		NodeKind.ForStmt => {
			const forInit = readNode(objHeap, arrHeap, h, "forInit", loc);
			const forCondition = readNode(objHeap, arrHeap, h, "forCondition", loc);
			const forUpdate = readNode(objHeap, arrHeap, h, "forUpdate", loc);
			const forBody = readNode(objHeap, arrHeap, h, "forBody", loc);
			return createNodeAt(NodeKind.ForStmt, { forInit, forCondition, forUpdate, forBody }, loc);
		},
		NodeKind.ForOfStmt => {
			const forOfBinding = readStr(objHeap, h, "forOfBinding");
			const forOfIsConst = readBool(objHeap, h, "forOfIsConst");
			const forOfIterable = readNode(objHeap, arrHeap, h, "forOfIterable", loc);
			const forOfBody = readNode(objHeap, arrHeap, h, "forOfBody", loc);
			return createNodeAt(NodeKind.ForOfStmt, {
				forOfBinding, forOfIsConst, forOfIterable, forOfBody,
				forOfPattern: null as unknown as Node, bindingLocation: loc,
			}, loc);
		},
		NodeKind.ForInStmt => {
			const forInBinding = readStr(objHeap, h, "forInBinding");
			const forInIsConst = readBool(objHeap, h, "forInIsConst");
			const forInObject = readNode(objHeap, arrHeap, h, "forInObject", loc);
			const forInBody = readNode(objHeap, arrHeap, h, "forInBody", loc);
			return createNodeAt(NodeKind.ForInStmt, { forInBinding, forInIsConst, forInObject, forInBody }, loc);
		},
		NodeKind.BreakStmt => {
			return createNodeAt(NodeKind.BreakStmt, { breakLabel: readStr(objHeap, h, "breakLabel") }, loc);
		},
		NodeKind.ContinueStmt => {
			return createNodeAt(NodeKind.ContinueStmt, { continueLabel: readStr(objHeap, h, "continueLabel") }, loc);
		},
		NodeKind.UnreachableStmt => {
			return createNodeAt(NodeKind.UnreachableStmt, { unreachableMsg: readStr(objHeap, h, "unreachableMsg") }, loc);
		},
		NodeKind.SwitchStmt => {
			const switchDisc = readNode(objHeap, arrHeap, h, "switchDisc", loc);
			const switchCases = readNodes(objHeap, arrHeap, h, "switchCases", loc);
			return createNodeAt(NodeKind.SwitchStmt, { switchDisc, switchCases }, loc);
		},
		NodeKind.SwitchCase => {
			const caseTests = readNodes(objHeap, arrHeap, h, "caseTests", loc);
			const caseStmts = readNodes(objHeap, arrHeap, h, "caseStmts", loc);
			const isDefault = readBool(objHeap, h, "isDefault");
			return createNodeAt(NodeKind.SwitchCase, { caseTests, caseStmts, isDefault }, loc);
		},
		NodeKind.MatchStmt => {
			const matchStmtDisc = readNode(objHeap, arrHeap, h, "matchStmtDisc", loc);
			const matchStmtCases = readNodes(objHeap, arrHeap, h, "matchStmtCases", loc);
			return createNodeAt(NodeKind.MatchStmt, { matchStmtDisc, matchStmtCases }, loc);
		},
		NodeKind.TryCatchStmt => {
			const tryBody = readNode(objHeap, arrHeap, h, "tryBody", loc);
			const catchName = readStr(objHeap, h, "catchName");
			const catchBody = readNode(objHeap, arrHeap, h, "catchBody", loc);
			const finallyBody = readNode(objHeap, arrHeap, h, "finallyBody", loc);
			return createNodeAt(NodeKind.TryCatchStmt, {
				tryBody, catchName, catchBody, finallyBody, catchBindingLocation: loc,
			}, loc);
		},

		// === Declarations ===
		NodeKind.FunctionDecl => {
			const fnName = readStr(objHeap, h, "fnName");
			const params = readStrs(objHeap, arrHeap, h, "params");
			const fnParamTypes = readStrs(objHeap, arrHeap, h, "fnParamTypes");
			const fnBody = readNode(objHeap, arrHeap, h, "fnBody", loc);
			const fnFlags = readStr(objHeap, h, "fnFlags");
			const fnReturnType = readStr(objHeap, h, "fnReturnType");
			return createNodeAt(NodeKind.FunctionDecl, {
				fnName, params, fnParamTypes, fnBody, fnFlags, fnReturnType,
				fnDefaults: [], nativeName: "", nameLocation: loc,
			}, loc);
		},
		NodeKind.ImportDecl => {
			const importNames = readStrs(objHeap, arrHeap, h, "importNames");
			const importAliases = readStrs(objHeap, arrHeap, h, "importAliases");
			const importSource = readStr(objHeap, h, "importSource");
			return createNodeAt(NodeKind.ImportDecl, {
				importNames, importAliases, importSource, nameLocations: [],
			}, loc);
		},
		NodeKind.ExportDecl => {
			const exportedDecl = readNode(objHeap, arrHeap, h, "exportedDecl", loc);
			return createNodeAt(NodeKind.ExportDecl, { exportedDecl }, loc);
		},
		NodeKind.TypeAliasDecl => {
			const aliasName = readStr(objHeap, h, "aliasName");
			const aliasType = readStr(objHeap, h, "aliasType");
			const aliasIsDistinct = readBool(objHeap, h, "aliasIsDistinct");
			return createNodeAt(NodeKind.TypeAliasDecl, {
				aliasName, aliasType, aliasIsDistinct,
				discriminantName: "", discriminantType: "",
				variantKeys: [], variantTypes: [], nameLocation: loc,
			}, loc);
		},
		NodeKind.EnumDecl => {
			const enumName = readStr(objHeap, h, "enumName");
			const enumMembers = readStrs(objHeap, arrHeap, h, "enumMembers");
			return createNodeAt(NodeKind.EnumDecl, {
				enumName, enumMembers, enumValues: [], nameLocation: loc, memberLocations: [],
			}, loc);
		},
		NodeKind.InterfaceDecl => {
			const interfaceName = readStr(objHeap, h, "interfaceName");
			const interfaceFields = readStrs(objHeap, arrHeap, h, "interfaceFields");
			const interfaceFieldTypes = readStrs(objHeap, arrHeap, h, "interfaceFieldTypes");
			return createNodeAt(NodeKind.InterfaceDecl, {
				interfaceName, interfaceFields, interfaceFieldTypes, nameLocation: loc,
			}, loc);
		},
		NodeKind.StructDecl => {
			const interfaceName = readStr(objHeap, h, "interfaceName");
			const interfaceFields = readStrs(objHeap, arrHeap, h, "interfaceFields");
			const interfaceFieldTypes = readStrs(objHeap, arrHeap, h, "interfaceFieldTypes");
			return createNodeAt(NodeKind.StructDecl, {
				interfaceName, interfaceFields, interfaceFieldTypes, nameLocation: loc,
			}, loc);
		},
		NodeKind.ClassDecl => {
			const className = readStr(objHeap, h, "className");
			const classExtends = readStr(objHeap, h, "classExtends");
			const classBody = readNodes(objHeap, arrHeap, h, "classBody", loc);
			return createNodeAt(NodeKind.ClassDecl, {
				className, classExtends, classBody, nameLocation: loc,
			}, loc);
		},
		NodeKind.ActorDecl => {
			const actorName = readStr(objHeap, h, "actorName");
			const actorBody = readNodes(objHeap, arrHeap, h, "actorBody", loc);
			return createNodeAt(NodeKind.ActorDecl, { actorName, actorBody, nameLocation: loc }, loc);
		},
		NodeKind.PropertyDecl => {
			const propName = readStr(objHeap, h, "propName");
			const propType = readStr(objHeap, h, "propType");
			const propIsStatic = readBool(objHeap, h, "propIsStatic");
			const propIsReadonly = readBool(objHeap, h, "propIsReadonly");
			const propVisibility = readStr(objHeap, h, "propVisibility");
			return createNodeAt(NodeKind.PropertyDecl, {
				propName, propType, propIsStatic, propIsReadonly, propVisibility,
				propInitializer: null as unknown as Node,
			}, loc);
		},
		NodeKind.MethodDecl => {
			const methodName = readStr(objHeap, h, "methodName");
			const methodParams = readStrs(objHeap, arrHeap, h, "methodParams");
			const methodParamTypes = readStrs(objHeap, arrHeap, h, "methodParamTypes");
			const methodBody = readNode(objHeap, arrHeap, h, "methodBody", loc);
			const methodIsStatic = readBool(objHeap, h, "methodIsStatic");
			const methodFlags = readStr(objHeap, h, "methodFlags");
			const methodVisibility = readStr(objHeap, h, "methodVisibility");
			const methodReturnType = readStr(objHeap, h, "methodReturnType");
			return createNodeAt(NodeKind.MethodDecl, {
				methodName, methodParams, methodParamTypes, methodBody,
				methodIsStatic, methodFlags, methodVisibility, methodReturnType,
				methodDefaults: [], nativeName: "", nameLocation: loc,
			}, loc);
		},
		NodeKind.ConstructorDecl => {
			const ctorParams = readStrs(objHeap, arrHeap, h, "ctorParams");
			const ctorParamTypes = readStrs(objHeap, arrHeap, h, "ctorParamTypes");
			const ctorBody = readNode(objHeap, arrHeap, h, "ctorBody", loc);
			return createNodeAt(NodeKind.ConstructorDecl, {
				ctorParams, ctorParamTypes, ctorBody, ctorDefaults: [],
			}, loc);
		},
		NodeKind.ExternDecl => {
			const externKind = readInt(objHeap, h, "externKind") as ExternKind;
			const externName = readStr(objHeap, h, "externName");
			const nativeName = readStr(objHeap, h, "nativeName");
			const externType = readStr(objHeap, h, "externType");
			return createNodeAt(NodeKind.ExternDecl, { externKind, externName, nativeName, externType }, loc);
		},
		NodeKind.MacroDecl => {
			const macroDeclName = readStr(objHeap, h, "macroDeclName");
			const macroDeclParams = readStrs(objHeap, arrHeap, h, "macroDeclParams");
			const macroDeclParamTypes = readStrs(objHeap, arrHeap, h, "macroDeclParamTypes");
			const macroDeclBody = readNode(objHeap, arrHeap, h, "macroDeclBody", loc);
			return createNodeAt(NodeKind.MacroDecl, { macroDeclName, macroDeclParams, macroDeclParamTypes, macroDeclBody }, loc);
		},
		NodeKind.DecoratedDecl => {
			const decorators = readNodes(objHeap, arrHeap, h, "decorators", loc);
			const decoratedNode = readNode(objHeap, arrHeap, h, "decoratedNode", loc);
			return createNodeAt(NodeKind.DecoratedDecl, { decorators, decoratedNode }, loc);
		},
		NodeKind.MacroInvocation => {
			const macroName = readStr(objHeap, h, "macroName");
			const macroArgs = readNodes(objHeap, arrHeap, h, "macroArgs", loc);
			return createNodeAt(NodeKind.MacroInvocation, { macroName, macroArgs }, loc);
		},

		// === Testing ===
		NodeKind.TestDecl => {
			const testName = readStr(objHeap, h, "testName");
			const testBody = readNode(objHeap, arrHeap, h, "testBody", loc);
			return createNodeAt(NodeKind.TestDecl, { testName, testBody }, loc);
		},
		NodeKind.AssertStmt => {
			const assertExpr = readNode(objHeap, arrHeap, h, "assertExpr", loc);
			const assertSource = readStr(objHeap, h, "assertSource");
			const assertMessage = readStr(objHeap, h, "assertMessage");
			return createNodeAt(NodeKind.AssertStmt, { assertExpr, assertSource, assertMessage }, loc);
		},

		// === Program ===
		NodeKind.Program => {
			const programStmts = readNodes(objHeap, arrHeap, h, "programStmts", loc);
			return createNodeAt(NodeKind.Program, { programStmts }, loc);
		},

		// === SpliceMany — A2 macro multi-decl emission ===
		NodeKind.SpliceMany => {
			const spliceNodes = readNodes(objHeap, arrHeap, h, "spliceNodes", loc);
			return createNodeAt(NodeKind.SpliceMany, { spliceNodes }, loc);
		},

		// === Type-AST kinds — V3: needed for nested-macro round-trip of type info ===
		// Other Type-AST kinds (TypeArray/TypeObject/TypeGeneric/TypeFunction)
		// retain default NullLiteral fallback — add cases as use cases surface.
		NodeKind.TypeUnion => {
			const typExprMembers = readNodes(objHeap, arrHeap, h, "typExprMembers", loc);
			const discFieldName = readStr(objHeap, h, "discFieldName");
			const variantKeys = readStrs(objHeap, arrHeap, h, "variantKeys");
			const discKind = readStr(objHeap, h, "discKind");
			return createNodeAt(NodeKind.TypeUnion, {
				typExprMembers, discFieldName, variantKeys, discKind,
			}, loc);
		},
		NodeKind.TypeIntersection => {
			const typExprMembers = readNodes(objHeap, arrHeap, h, "typExprMembers", loc);
			return createNodeAt(NodeKind.TypeIntersection, { typExprMembers }, loc);
		},

		// === JSX (compile-time only — reverse of nodeToValue JSX cases) ===
		NodeKind.JSXElement => {
			const jsxTag = readStr(objHeap, h, "jsxTag");
			const jsxAttrs = readNodes(objHeap, arrHeap, h, "jsxAttrs", loc);
			const jsxChildren = readNodes(objHeap, arrHeap, h, "jsxChildren", loc);
			const jsxSelfClosing = readBool(objHeap, h, "jsxSelfClosing");
			return createNodeAt(NodeKind.JSXElement, { jsxTag, jsxAttrs, jsxChildren, jsxSelfClosing }, loc);
		},
		NodeKind.JSXFragment => {
			const jsxFragChildren = readNodes(objHeap, arrHeap, h, "jsxFragChildren", loc);
			return createNodeAt(NodeKind.JSXFragment, { jsxFragChildren }, loc);
		},
		NodeKind.JSXText => {
			const jsxText = readStr(objHeap, h, "jsxText");
			return createNodeAt(NodeKind.JSXText, { jsxText }, loc);
		},
		NodeKind.JSXExpressionContainer => {
			const jsxExpr = readNode(objHeap, arrHeap, h, "jsxExpr", loc);
			return createNodeAt(NodeKind.JSXExpressionContainer, { jsxExpr }, loc);
		},
		NodeKind.JSXAttribute => {
			const jsxAttrName = readStr(objHeap, h, "jsxAttrName");
			const jsxAttrValue = readNode(objHeap, arrHeap, h, "jsxAttrValue", loc);
			return createNodeAt(NodeKind.JSXAttribute, { jsxAttrName, jsxAttrValue }, loc);
		},
		NodeKind.JSXSpreadAttribute => {
			const jsxSpreadArg = readNode(objHeap, arrHeap, h, "jsxSpreadArg", loc);
			return createNodeAt(NodeKind.JSXSpreadAttribute, { jsxSpreadArg }, loc);
		},

		// Unknown kind — return a NullLiteral as safe fallback
		_ => createNodeAt(NodeKind.NullLiteral, { nullPlaceholder: true }, loc),
	};
}

// ===== Tests =====

test "NumberLiteral serialization" {
	const objHeap = createStructHeap();
	const arrHeap = createArrayHeap();
	const loc = makeLoc(5, 10);
	const node = mkNumber(42, loc);
	const val = nodeToValue(node, objHeap, arrHeap);
	assert val.kind === RaiserValueKind.Object;
	const kindVal = heapObjectGetField(objHeap, val.intVal, "kind");
	assert kindVal.intVal === (NodeKind.NumberLiteral as number);
	const numVal = heapObjectGetField(objHeap, val.intVal, "value");
	assert numVal.floatVal === 42;
	const lineVal = heapObjectGetField(objHeap, val.intVal, "line");
	assert lineVal.intVal === 5;
}

test "StringLiteral serialization" {
	const objHeap = createStructHeap();
	const arrHeap = createArrayHeap();
	const loc = makeLoc(1, 0);
	const node = mkString("hello", loc);
	const val = nodeToValue(node, objHeap, arrHeap);
	assert val.kind === RaiserValueKind.Object;
	const kindVal = heapObjectGetField(objHeap, val.intVal, "kind");
	assert kindVal.intVal === (NodeKind.StringLiteral as number);
	const strVal = heapObjectGetField(objHeap, val.intVal, "value");
	assert strVal.strVal === "hello";
}

test "BooleanLiteral serialization" {
	const objHeap = createStructHeap();
	const arrHeap = createArrayHeap();
	const loc = makeLoc(1, 0);
	const node = mkBool(true, loc);
	const val = nodeToValue(node, objHeap, arrHeap);
	assert val.kind === RaiserValueKind.Object;
	const kindVal = heapObjectGetField(objHeap, val.intVal, "kind");
	assert kindVal.intVal === (NodeKind.BooleanLiteral as number);
	const bVal = heapObjectGetField(objHeap, val.intVal, "boolValue");
	assert bVal.intVal === 1;
}

test "Identifier serialization" {
	const objHeap = createStructHeap();
	const arrHeap = createArrayHeap();
	const loc = makeLoc(1, 0);
	const node = createNode(NodeKind.Identifier, { name: "foo" }, synthToken(loc));
	const val = nodeToValue(node, objHeap, arrHeap);
	assert val.kind === RaiserValueKind.Object;
	const kindVal = heapObjectGetField(objHeap, val.intVal, "kind");
	assert kindVal.intVal === (NodeKind.Identifier as number);
	const nameVal = heapObjectGetField(objHeap, val.intVal, "name");
	assert nameVal.strVal === "foo";
}

test "BinaryExpr serialization" {
	const objHeap = createStructHeap();
	const arrHeap = createArrayHeap();
	const loc = makeLoc(1, 0);
	const left = mkNumber(2, loc);
	const right = mkNumber(3, loc);
	const binNode = createNode(NodeKind.BinaryExpr, {
		operator: "+", left, right,
	}, synthToken(loc));
	const val = nodeToValue(binNode, objHeap, arrHeap);
	assert val.kind === RaiserValueKind.Object;
	const opVal = heapObjectGetField(objHeap, val.intVal, "operator");
	assert opVal.strVal === "+";
	const leftVal = heapObjectGetField(objHeap, val.intVal, "left");
	assert leftVal.kind === RaiserValueKind.Object;
	const leftKind = heapObjectGetField(objHeap, leftVal.intVal, "kind");
	assert leftKind.intVal === (NodeKind.NumberLiteral as number);
	const rightVal = heapObjectGetField(objHeap, val.intVal, "right");
	assert rightVal.kind === RaiserValueKind.Object;
	const rightKind = heapObjectGetField(objHeap, rightVal.intVal, "kind");
	assert rightKind.intVal === (NodeKind.NumberLiteral as number);
}

// ===== Round-trip tests (Phase A3) =====

test "round-trip NumberLiteral" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const orig = mkNumber(42, makeLoc(1, 0));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, orig.location);
	assert back.kind === NodeKind.NumberLiteral;
	const d = back.data as NumberLiteralData;
	assert d.value === 42;
}

test "round-trip StringLiteral" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const orig = mkString("hello", makeLoc(1, 0));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, orig.location);
	assert back.kind === NodeKind.StringLiteral;
	const d = back.data as StringLiteralData;
	assert d.value === "hello";
}

test "round-trip BooleanLiteral" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const orig = mkBool(true, makeLoc(1, 0));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, orig.location);
	assert back.kind === NodeKind.BooleanLiteral;
	const d = back.data as BooleanLiteralData;
	assert d.boolValue === true;
}

test "round-trip Identifier" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(2, 5);
	const orig = createNode(NodeKind.Identifier, { name: "myVar" }, synthToken(loc));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, loc);
	assert back.kind === NodeKind.Identifier;
	const d = back.data as IdentifierData;
	assert d.name === "myVar";
}

test "round-trip BinaryExpr" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const left = mkNumber(1, loc);
	const right = mkNumber(2, loc);
	const orig = createNode(NodeKind.BinaryExpr, { operator: "+", left, right }, synthToken(loc));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, loc);
	assert back.kind === NodeKind.BinaryExpr;
	const d = back.data as BinaryExprData;
	assert d.operator === "+";
	assert d.left.kind === NodeKind.NumberLiteral;
	assert d.right.kind === NodeKind.NumberLiteral;
	assert (d.left.data as NumberLiteralData).value === 1;
	assert (d.right.data as NumberLiteralData).value === 2;
}

test "round-trip CallExpr with arguments" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const callee = createNode(NodeKind.Identifier, { name: "log" }, synthToken(loc));
	const args = [mkString("hello", loc), mkNumber(42, loc)];
	const orig = createNode(NodeKind.CallExpr, {
		callee, arguments: args, isDirectCall: true, resolvedOverloadIdx: 0,
	}, synthToken(loc));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, loc);
	assert back.kind === NodeKind.CallExpr;
	const d = back.data as CallExprData;
	assert d.callee.kind === NodeKind.Identifier;
	assert d.arguments.length === 2;
	assert d.arguments[0].kind === NodeKind.StringLiteral;
	assert d.arguments[1].kind === NodeKind.NumberLiteral;
}

test "round-trip MemberExpr" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const obj = createNode(NodeKind.Identifier, { name: "foo" }, synthToken(loc));
	const orig = createNode(NodeKind.MemberExpr, {
		object: obj, property: "bar", isOptional: false,
	}, synthToken(loc));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, loc);
	assert back.kind === NodeKind.MemberExpr;
	const d = back.data as MemberExprData;
	assert d.property === "bar";
	assert d.object.kind === NodeKind.Identifier;
}

test "round-trip BlockStmt with statements" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const ret = createNode(NodeKind.ReturnStmt, { argument: mkNumber(7, loc) }, synthToken(loc));
	const orig = createNode(NodeKind.BlockStmt, { statements: [ret] }, synthToken(loc));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, loc);
	assert back.kind === NodeKind.BlockStmt;
	const d = back.data as BlockStmtData;
	assert d.statements.length === 1;
	assert d.statements[0].kind === NodeKind.ReturnStmt;
}

test "round-trip IfStmt" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const cond = mkBool(true, loc);
	const cons = createNode(NodeKind.BlockStmt, { statements: [] }, synthToken(loc));
	const alt = createNode(NodeKind.BlockStmt, { statements: [] }, synthToken(loc));
	const orig = createNode(NodeKind.IfStmt, { condition: cond, consequent: cons, alternate: alt }, synthToken(loc));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, loc);
	assert back.kind === NodeKind.IfStmt;
	const d = back.data as IfStmtData;
	assert d.condition.kind === NodeKind.BooleanLiteral;
	assert d.consequent.kind === NodeKind.BlockStmt;
	assert d.alternate.kind === NodeKind.BlockStmt;
}

test "round-trip VariableDecl" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(3, 0);
	const init = mkNumber(100, loc);
	const orig = createNode(NodeKind.VariableDecl, {
		declName: "x", declType: "number", initializer: init,
		declKind: DeclKind.Const, nameLocation: loc,
	}, synthToken(loc));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, loc);
	assert back.kind === NodeKind.VariableDecl;
	const d = back.data as VariableDeclData;
	assert d.declName === "x";
	assert d.declType === "number";
	assert d.declKind === DeclKind.Const;
	assert d.initializer.kind === NodeKind.NumberLiteral;
}

test "round-trip FunctionDecl" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const body = createNode(NodeKind.BlockStmt, { statements: [] }, synthToken(loc));
	const orig = createNode(NodeKind.FunctionDecl, {
		fnName: "add", params: ["a", "b"], fnParamTypes: ["number", "number"],
		fnBody: body, fnFlags: "", fnReturnType: "number",
		fnDefaults: [], nativeName: "", nameLocation: loc,
	}, synthToken(loc));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, loc);
	assert back.kind === NodeKind.FunctionDecl;
	const d = back.data as FunctionDeclData;
	assert d.fnName === "add";
	assert d.params.length === 2;
	assert d.params[0] === "a";
	assert d.params[1] === "b";
	assert d.fnReturnType === "number";
}

test "round-trip ImportDecl" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const orig = createNode(NodeKind.ImportDecl, {
		importNames: ["X", "Y"], importAliases: ["X", "Z"],
		importSource: "./mod", nameLocations: [],
	}, synthToken(loc));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, loc);
	assert back.kind === NodeKind.ImportDecl;
	const d = back.data as ImportDeclData;
	assert d.importNames.length === 2;
	assert d.importNames[0] === "X";
	assert d.importAliases[1] === "Z";
	assert d.importSource === "./mod";
}

test "round-trip Program with multiple statements" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const decl = createNode(NodeKind.VariableDecl, {
		declName: "x", declType: "", initializer: mkNumber(1, loc),
		declKind: DeclKind.Const, nameLocation: loc,
	}, synthToken(loc));
	const ret = createNode(NodeKind.ReturnStmt, { argument: createNode(NodeKind.Identifier, { name: "x" }, synthToken(loc)) }, synthToken(loc));
	const orig = createNode(NodeKind.Program, { programStmts: [decl, ret] }, synthToken(loc));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, loc);
	assert back.kind === NodeKind.Program;
	const d = back.data as ProgramData;
	assert d.programStmts.length === 2;
	assert d.programStmts[0].kind === NodeKind.VariableDecl;
	assert d.programStmts[1].kind === NodeKind.ReturnStmt;
}

// ===== A2 Day 1 — SpliceMany schema round-trip =====

test "round-trip SpliceMany with multiple decls" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const a = createNode(NodeKind.VariableDecl, {
		declName: "a", declType: "", initializer: mkNumber(1, loc),
		declKind: DeclKind.Const, nameLocation: loc,
	}, synthToken(loc));
	const b = createNode(NodeKind.VariableDecl, {
		declName: "b", declType: "", initializer: mkNumber(2, loc),
		declKind: DeclKind.Const, nameLocation: loc,
	}, synthToken(loc));
	const orig = createNodeAt(NodeKind.SpliceMany, { spliceNodes: [a, b] }, loc);
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, loc);
	assert back.kind === NodeKind.SpliceMany;
	const d = back.data as SpliceManyData;
	assert d.spliceNodes.length === 2;
	assert d.spliceNodes[0].kind === NodeKind.VariableDecl;
	assert (d.spliceNodes[0].data as VariableDeclData).declName === "a";
	assert d.spliceNodes[1].kind === NodeKind.VariableDecl;
	assert (d.spliceNodes[1].data as VariableDeclData).declName === "b";
}

test "round-trip empty SpliceMany" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const orig = createNodeAt(NodeKind.SpliceMany, { spliceNodes: [] }, loc);
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, loc);
	assert back.kind === NodeKind.SpliceMany;
	assert (back.data as SpliceManyData).spliceNodes.length === 0;
}

test "round-trip nested expressions" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	// (1 + 2) * 3
	const inner = createNode(NodeKind.BinaryExpr, {
		operator: "+", left: mkNumber(1, loc), right: mkNumber(2, loc),
	}, synthToken(loc));
	const orig = createNode(NodeKind.BinaryExpr, {
		operator: "*", left: inner, right: mkNumber(3, loc),
	}, synthToken(loc));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, loc);
	assert back.kind === NodeKind.BinaryExpr;
	const outer = back.data as BinaryExprData;
	assert outer.operator === "*";
	assert outer.left.kind === NodeKind.BinaryExpr;
	const innerBack = outer.left.data as BinaryExprData;
	assert innerBack.operator === "+";
	assert (innerBack.left.data as NumberLiteralData).value === 1;
	assert (innerBack.right.data as NumberLiteralData).value === 2;
	assert (outer.right.data as NumberLiteralData).value === 3;
}

test "round-trip MatchCase with guard" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const pat = mkNumber(1, loc);
	// guard: x > 0  (a BinaryExpr standing in for a real guard)
	const guard = createNode(NodeKind.BinaryExpr, {
		operator: ">",
		left: createNode(NodeKind.Identifier, { name: "x" }, synthToken(loc)),
		right: mkNumber(0, loc),
	}, synthToken(loc));
	const body = createNode(NodeKind.BlockStmt, { statements: [] }, synthToken(loc));
	const orig = createNode(NodeKind.MatchCase, {
		casePatterns: [pat], caseGuard: guard, caseBody: body,
	}, synthToken(loc));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, loc);
	assert back.kind === NodeKind.MatchCase;
	const d = back.data as MatchCaseData;
	assert d.casePatterns.length === 1;
	assert d.caseGuard !== null;
	assert d.caseGuard.kind === NodeKind.BinaryExpr;
	assert (d.caseGuard.data as BinaryExprData).operator === ">";
}

test "round-trip MatchCase without guard (null)" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const pat = mkNumber(1, loc);
	const body = createNode(NodeKind.BlockStmt, { statements: [] }, synthToken(loc));
	const orig = createNode(NodeKind.MatchCase, {
		casePatterns: [pat], caseGuard: null as unknown as Node, caseBody: body,
	}, synthToken(loc));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, loc);
	assert back.kind === NodeKind.MatchCase;
	const d = back.data as MatchCaseData;
	assert d.caseGuard === null;
}

// ===== mapTypeToAst tests — Day 1 (atomic types) =====

// Local helper: construct a primitive Type without depending on checker/types.ms.
// Mirrors the shape returned by emptyType() + a kind override.
function makePrimType(k: TypeKind): Type {
	return {
		kind: k,
		typeName: "",
		typeNames: [],
		typeChildren: [],
		typeReturn: null,
		typeExtra: null,
		typeFlags: 0,
		callConv: CallingConvention.CcDefault,
		attachedOps: [],
		sym: null,
	};
}

test "mapTypeToAst — number primitive emits Identifier(\"number\")" {
	const out = mapTypeToAst(makePrimType(TypeKind.Number), makeLoc(1, 0));
	assert out.kind === NodeKind.Identifier;
	assert (out.data as IdentifierData).name === "number";
}

test "mapTypeToAst — string primitive emits Identifier(\"string\")" {
	const out = mapTypeToAst(makePrimType(TypeKind.String), makeLoc(1, 0));
	assert out.kind === NodeKind.Identifier;
	assert (out.data as IdentifierData).name === "string";
}

test "mapTypeToAst — boolean primitive emits Identifier(\"boolean\")" {
	const out = mapTypeToAst(makePrimType(TypeKind.Boolean), makeLoc(1, 0));
	assert out.kind === NodeKind.Identifier;
	assert (out.data as IdentifierData).name === "boolean";
}

test "mapTypeToAst — int32 primitive emits Identifier(\"int32\")" {
	const out = mapTypeToAst(makePrimType(TypeKind.Int32), makeLoc(1, 0));
	assert out.kind === NodeKind.Identifier;
	assert (out.data as IdentifierData).name === "int32";
}

test "mapTypeToAst — float64 primitive emits Identifier(\"float64\")" {
	const out = mapTypeToAst(makePrimType(TypeKind.Float64), makeLoc(1, 0));
	assert out.kind === NodeKind.Identifier;
	assert (out.data as IdentifierData).name === "float64";
}

test "mapTypeToAst — null type emits Identifier(\"<null>\") sentinel" {
	const loc = makeLoc(1, 0);
	const out = mapTypeToAst(null, loc);
	assert out.kind === NodeKind.Identifier;
	assert (out.data as IdentifierData).name === "<null>";
}

test "mapTypeToAst — not-yet-handled kind falls back to typeName when set" {
	const loc = makeLoc(1, 0);
	// TypeKind.Enum is a Day 5+ handler, falls through to typeName placeholder today.
	const t = makePrimType(TypeKind.Enum);
	t.typeName = "Color";
	const out = mapTypeToAst(t, loc);
	assert out.kind === NodeKind.Identifier;
	assert (out.data as IdentifierData).name === "Color";
}

test "mapTypeToAst — not-yet-handled kind with no typeName emits Identifier(\"unknown\")" {
	const loc = makeLoc(1, 0);
	const out = mapTypeToAst(makePrimType(TypeKind.Enum), loc);
	assert out.kind === NodeKind.Identifier;
	assert (out.data as IdentifierData).name === "unknown";
}

// ===== mapTypeToAst tests — Day 2 (Struct → TypeObject) =====

function makeStructType(name: string, fieldNames: string[], fieldTypes: Type[]): Type {
	const t = makePrimType(TypeKind.Struct);
	t.typeName = name;
	t.typeNames = fieldNames;
	t.typeChildren = fieldTypes;
	return t;
}

test "mapTypeToAst — Struct emits TypeObject with field names + types" {
	const loc = makeLoc(1, 0);
	const t = makeStructType("User", ["name", "age"], [makePrimType(TypeKind.String), makePrimType(TypeKind.Int32)]);
	const out = mapTypeToAst(t, loc);
	assert out.kind === NodeKind.TypeObject;
	const d = out.data as TypeObjectData;
	assert d.typExprFieldNames.length === 2;
	assert d.typExprFieldNames[0] === "name";
	assert d.typExprFieldNames[1] === "age";
	assert d.typExprFieldTypes.length === 2;
	assert d.typExprFieldTypes[0].kind === NodeKind.Identifier;
	assert (d.typExprFieldTypes[0].data as IdentifierData).name === "string";
	assert (d.typExprFieldTypes[1].data as IdentifierData).name === "int32";
	assert d.typExprIndexKey === null;
	assert d.typExprIndexValue === null;
}

test "mapTypeToAst — empty Struct emits TypeObject with empty arrays" {
	const loc = makeLoc(1, 0);
	const out = mapTypeToAst(makeStructType("Empty", [], []), loc);
	assert out.kind === NodeKind.TypeObject;
	const d = out.data as TypeObjectData;
	assert d.typExprFieldNames.length === 0;
	assert d.typExprFieldTypes.length === 0;
}

test "mapTypeToAst — nested Struct recurses into TypeObject field types" {
	const loc = makeLoc(1, 0);
	const inner = makeStructType("Inner", ["x"], [makePrimType(TypeKind.Int32)]);
	const outer = makeStructType("Outer", ["payload"], [inner]);
	const out = mapTypeToAst(outer, loc);
	assert out.kind === NodeKind.TypeObject;
	const d = out.data as TypeObjectData;
	assert d.typExprFieldTypes.length === 1;
	assert d.typExprFieldTypes[0].kind === NodeKind.TypeObject;
	const innerData = d.typExprFieldTypes[0].data as TypeObjectData;
	assert innerData.typExprFieldNames[0] === "x";
	assert (innerData.typExprFieldTypes[0].data as IdentifierData).name === "int32";
}

test "mapTypeToAst — anonymous Struct (empty typeName) still emits TypeObject" {
	const loc = makeLoc(1, 0);
	const out = mapTypeToAst(makeStructType("", ["v"], [makePrimType(TypeKind.Boolean)]), loc);
	assert out.kind === NodeKind.TypeObject;
	const d = out.data as TypeObjectData;
	assert d.typExprFieldNames[0] === "v";
	assert (d.typExprFieldTypes[0].data as IdentifierData).name === "boolean";
	// V2: decorators array initialized empty for non-class types
	assert d.typExprFieldDecorators.length === 1;
	assert d.typExprFieldDecorators[0].length === 0;
}

// ===== mapTypeToAst tests — V2 (decorators on class fields) =====

// Build a synthetic ClassDecl Node with decorated fields, attach it as
// declNode of a Symbol. Mirrors what the checker produces for a real class.
function makeDecoratedField(propName: string, propType: string, decorators: Node[]): Node {
	const loc = makeLoc(1, 0);
	const propNode = createNodeAt(NodeKind.PropertyDecl, {
		propName, propType, propIsStatic: false, propIsReadonly: false,
		propVisibility: "",
		propInitializer: null as unknown as Node,
	}, loc);
	if (decorators.length === 0) return propNode;
	return createNodeAt(NodeKind.DecoratedDecl, {
		decorators, decoratedNode: propNode,
	}, loc);
}

function makeClassWithDecoratedFields(name: string, fieldNames: string[], fieldDecorators: Node[][]): Type {
	const loc = makeLoc(1, 0);
	const classBody: Node[] = [];
	for (let i = 0; i < fieldNames.length; i = i + 1) {
		classBody.push(makeDecoratedField(fieldNames[i], "string", fieldDecorators[i]));
	}
	const classDecl = createNodeAt(NodeKind.ClassDecl, {
		className: name, classExtends: "", classBody,
		nameLocation: loc,
	}, loc);
	const t = makePrimType(TypeKind.Struct);
	t.typeName = name;
	t.typeNames = fieldNames;
	const fieldTypes: Type[] = [];
	for (let i = 0; i < fieldNames.length; i = i + 1) fieldTypes.push(makePrimType(TypeKind.String));
	t.typeChildren = fieldTypes;
	t.sym = makeSymbol(name, SymbolKind.Class);
	t.sym.declNode = classDecl;
	return t;
}

test "mapTypeToAst — class field with @rename decorator surfaces in typExprFieldDecorators" {
	const loc = makeLoc(1, 0);
	const renameDecorator = createNodeAt(NodeKind.CallExpr, {
		callee: createNodeAt(NodeKind.Identifier, { name: "rename" }, loc),
		arguments: [createNodeAt(NodeKind.StringLiteral, { value: "_id" }, loc)],
	}, loc);
	const t = makeClassWithDecoratedFields("Doc", ["id", "name"], [[renameDecorator], []]);
	const out = mapTypeToAst(t, loc);
	assert out.kind === NodeKind.TypeObject;
	const d = out.data as TypeObjectData;
	assert d.typExprFieldDecorators.length === 2;
	// Field 0 (id) has the rename decorator
	assert d.typExprFieldDecorators[0].length === 1;
	assert d.typExprFieldDecorators[0][0].kind === NodeKind.CallExpr;
	// Field 1 (name) has none
	assert d.typExprFieldDecorators[1].length === 0;
}

test "mapTypeToAst — class with multiple decorators on one field preserves order" {
	const loc = makeLoc(1, 0);
	const dec1 = createNodeAt(NodeKind.Identifier, { name: "skip" }, loc);
	const dec2 = createNodeAt(NodeKind.Identifier, { name: "validate" }, loc);
	const t = makeClassWithDecoratedFields("Item", ["v"], [[dec1, dec2]]);
	const out = mapTypeToAst(t, loc);
	const d = out.data as TypeObjectData;
	assert d.typExprFieldDecorators[0].length === 2;
	assert (d.typExprFieldDecorators[0][0].data as IdentifierData).name === "skip";
	assert (d.typExprFieldDecorators[0][1].data as IdentifierData).name === "validate";
}

test "mapTypeToAst — non-class Struct (interface-style, no declNode) gets empty decorators" {
	const loc = makeLoc(1, 0);
	const t = makeStructType("Iface", ["a", "b"], [makePrimType(TypeKind.Int32), makePrimType(TypeKind.String)]);
	// No sym/declNode set
	const out = mapTypeToAst(t, loc);
	const d = out.data as TypeObjectData;
	assert d.typExprFieldDecorators.length === 2;
	assert d.typExprFieldDecorators[0].length === 0;
	assert d.typExprFieldDecorators[1].length === 0;
}

test "mapTypeToAst — methods in classBody are skipped (V2 scope = fields only)" {
	const loc = makeLoc(1, 0);
	const propDec = createNodeAt(NodeKind.Identifier, { name: "rename" }, loc);
	// Build a class with: a decorated property + a method (which should be ignored)
	const propNode = createNodeAt(NodeKind.PropertyDecl, {
		propName: "id", propType: "string", propIsStatic: false, propIsReadonly: false,
		propVisibility: "",
		propInitializer: null as unknown as Node,
	}, loc);
	const decoratedProp = createNodeAt(NodeKind.DecoratedDecl, {
		decorators: [propDec], decoratedNode: propNode,
	}, loc);
	const methodNode = createNodeAt(NodeKind.MethodDecl, {
		methodName: "toString", methodParams: [], methodParamTypes: [],
		methodBody: createNodeAt(NodeKind.BlockStmt, { statements: [] }, loc),
		methodIsStatic: false, methodFlags: "", methodVisibility: "", methodReturnType: "string",
		methodDefaults: [], nativeName: "", nameLocation: loc,
	}, loc);
	const classDecl = createNodeAt(NodeKind.ClassDecl, {
		className: "Mixed", classExtends: "",
		classBody: [decoratedProp, methodNode],
		nameLocation: loc,
	}, loc);
	const t = makePrimType(TypeKind.Struct);
	t.typeName = "Mixed";
	t.typeNames = ["id"];
	t.typeChildren = [makePrimType(TypeKind.String)];
	t.sym = makeSymbol("Mixed", SymbolKind.Class);
	t.sym.declNode = classDecl;
	const out = mapTypeToAst(t, loc);
	const d = out.data as TypeObjectData;
	assert d.typExprFieldDecorators.length === 1;
	assert d.typExprFieldDecorators[0].length === 1;  // method ignored, only field's decorator surfaces
	assert (d.typExprFieldDecorators[0][0].data as IdentifierData).name === "rename";
}

test "mapTypeToAst — class wrapped in ExportDecl peels through to find class body" {
	const loc = makeLoc(1, 0);
	const dec = createNodeAt(NodeKind.Identifier, { name: "validate" }, loc);
	const t = makeClassWithDecoratedFields("Exp", ["v"], [[dec]]);
	// Wrap declNode in ExportDecl
	const exportDecl = createNodeAt(NodeKind.ExportDecl, {
		exportedDecl: t.sym.declNode,
	}, loc);
	t.sym.declNode = exportDecl;
	const out = mapTypeToAst(t, loc);
	const d = out.data as TypeObjectData;
	assert d.typExprFieldDecorators[0].length === 1;
	assert (d.typExprFieldDecorators[0][0].data as IdentifierData).name === "validate";
}

// ===== mapTypeToAst tests — Day 3 (Array / SizedArray / Span → TypeArray) =====

function makeArrayType(kind: TypeKind, element: Type, size: number): Type {
	const t = makePrimType(kind);
	t.typeReturn = element;
	t.typeFlags = size;
	return t;
}

test "mapTypeToAst — Array<T> emits TypeArray with size=-1" {
	const loc = makeLoc(1, 0);
	const out = mapTypeToAst(makeArrayType(TypeKind.Array, makePrimType(TypeKind.Int32), 0), loc);
	assert out.kind === NodeKind.TypeArray;
	const d = out.data as TypeArrayData;
	assert d.typExprSize === -1;
	assert d.typExprElement.kind === NodeKind.Identifier;
	assert (d.typExprElement.data as IdentifierData).name === "int32";
}

test "mapTypeToAst — SizedArray<T, N> emits TypeArray with size=N" {
	const loc = makeLoc(1, 0);
	const out = mapTypeToAst(makeArrayType(TypeKind.SizedArray, makePrimType(TypeKind.Float64), 16), loc);
	assert out.kind === NodeKind.TypeArray;
	const d = out.data as TypeArrayData;
	assert d.typExprSize === 16;
	assert (d.typExprElement.data as IdentifierData).name === "float64";
}

test "mapTypeToAst — Span<T> emits TypeArray with size=-1" {
	const loc = makeLoc(1, 0);
	const out = mapTypeToAst(makeArrayType(TypeKind.Span, makePrimType(TypeKind.String), 0), loc);
	assert out.kind === NodeKind.TypeArray;
	const d = out.data as TypeArrayData;
	assert d.typExprSize === -1;
	assert (d.typExprElement.data as IdentifierData).name === "string";
}

test "mapTypeToAst — Array<Array<T>> emits nested TypeArray" {
	const loc = makeLoc(1, 0);
	const inner = makeArrayType(TypeKind.Array, makePrimType(TypeKind.Int32), 0);
	const outer = makeArrayType(TypeKind.Array, inner, 0);
	const out = mapTypeToAst(outer, loc);
	assert out.kind === NodeKind.TypeArray;
	const d = out.data as TypeArrayData;
	assert d.typExprElement.kind === NodeKind.TypeArray;
	const innerData = d.typExprElement.data as TypeArrayData;
	assert (innerData.typExprElement.data as IdentifierData).name === "int32";
}

test "mapTypeToAst — SizedArray with Substituting flag bit masked from size" {
	const loc = makeLoc(1, 0);
	const t = makeArrayType(TypeKind.SizedArray, makePrimType(TypeKind.Int32), 8);
	t.typeFlags = (8 + TypeFlag.Substituting) as int32;
	const out = mapTypeToAst(t, loc);
	const d = out.data as TypeArrayData;
	assert d.typExprSize === 8;
}

test "mapTypeToAst — Array<Struct> embeds TypeObject as element" {
	const loc = makeLoc(1, 0);
	const struct = makeStructType("Item", ["id"], [makePrimType(TypeKind.Int32)]);
	const arr = makeArrayType(TypeKind.Array, struct, 0);
	const out = mapTypeToAst(arr, loc);
	assert out.kind === NodeKind.TypeArray;
	const d = out.data as TypeArrayData;
	assert d.typExprElement.kind === NodeKind.TypeObject;
	const elemData = d.typExprElement.data as TypeObjectData;
	assert elemData.typExprFieldNames[0] === "id";
}

// ===== mapTypeToAst tests — Day 4 (GenericInstance / GenericParam) =====

function makeGenericInstance(name: string, args: Type[]): Type {
	const t = makePrimType(TypeKind.GenericInstance);
	t.typeName = name;
	t.typeChildren = args;
	return t;
}

function makeGenericParam(name: string): Type {
	const t = makePrimType(TypeKind.GenericParam);
	t.typeName = name;
	return t;
}

test "mapTypeToAst — GenericInstance Container<int32> emits TypeGeneric" {
	const loc = makeLoc(1, 0);
	const t = makeGenericInstance("Container", [makePrimType(TypeKind.Int32)]);
	const out = mapTypeToAst(t, loc);
	assert out.kind === NodeKind.TypeGeneric;
	const d = out.data as TypeGenericData;
	assert d.typExprBase.kind === NodeKind.Identifier;
	assert (d.typExprBase.data as IdentifierData).name === "Container";
	assert d.typExprArgs.length === 1;
	assert (d.typExprArgs[0].data as IdentifierData).name === "int32";
}

test "mapTypeToAst — GenericInstance Map<string, int32> emits two-arg TypeGeneric" {
	const loc = makeLoc(1, 0);
	const t = makeGenericInstance("Map", [makePrimType(TypeKind.String), makePrimType(TypeKind.Int32)]);
	const out = mapTypeToAst(t, loc);
	assert out.kind === NodeKind.TypeGeneric;
	const d = out.data as TypeGenericData;
	assert (d.typExprBase.data as IdentifierData).name === "Map";
	assert d.typExprArgs.length === 2;
	assert (d.typExprArgs[0].data as IdentifierData).name === "string";
	assert (d.typExprArgs[1].data as IdentifierData).name === "int32";
}

test "mapTypeToAst — GenericInstance with no args emits TypeGeneric with empty args" {
	const loc = makeLoc(1, 0);
	const out = mapTypeToAst(makeGenericInstance("Bare", []), loc);
	assert out.kind === NodeKind.TypeGeneric;
	const d = out.data as TypeGenericData;
	assert (d.typExprBase.data as IdentifierData).name === "Bare";
	assert d.typExprArgs.length === 0;
}

test "mapTypeToAst — GenericInstance with anonymous base falls back to <anon-generic>" {
	const loc = makeLoc(1, 0);
	const out = mapTypeToAst(makeGenericInstance("", [makePrimType(TypeKind.Boolean)]), loc);
	assert out.kind === NodeKind.TypeGeneric;
	const d = out.data as TypeGenericData;
	assert (d.typExprBase.data as IdentifierData).name === "<anon-generic>";
}

test "mapTypeToAst — nested GenericInstance Result<Container<int32>, string>" {
	const loc = makeLoc(1, 0);
	const inner = makeGenericInstance("Container", [makePrimType(TypeKind.Int32)]);
	const outer = makeGenericInstance("Result", [inner, makePrimType(TypeKind.String)]);
	const out = mapTypeToAst(outer, loc);
	assert out.kind === NodeKind.TypeGeneric;
	const d = out.data as TypeGenericData;
	assert (d.typExprBase.data as IdentifierData).name === "Result";
	assert d.typExprArgs.length === 2;
	assert d.typExprArgs[0].kind === NodeKind.TypeGeneric;
	const innerData = d.typExprArgs[0].data as TypeGenericData;
	assert (innerData.typExprBase.data as IdentifierData).name === "Container";
	assert (innerData.typExprArgs[0].data as IdentifierData).name === "int32";
	assert (d.typExprArgs[1].data as IdentifierData).name === "string";
}

test "mapTypeToAst — GenericParam T emits Identifier(\"T\")" {
	const loc = makeLoc(1, 0);
	const out = mapTypeToAst(makeGenericParam("T"), loc);
	assert out.kind === NodeKind.Identifier;
	assert (out.data as IdentifierData).name === "T";
}

test "mapTypeToAst — anonymous GenericParam falls back to Identifier(\"T\")" {
	const loc = makeLoc(1, 0);
	const out = mapTypeToAst(makeGenericParam(""), loc);
	assert out.kind === NodeKind.Identifier;
	assert (out.data as IdentifierData).name === "T";
}

test "mapTypeToAst — GenericInstance carrying GenericParam (uninstantiated) preserves param name" {
	const loc = makeLoc(1, 0);
	const t = makeGenericInstance("Container", [makeGenericParam("U")]);
	const out = mapTypeToAst(t, loc);
	assert out.kind === NodeKind.TypeGeneric;
	const d = out.data as TypeGenericData;
	assert d.typExprArgs.length === 1;
	assert d.typExprArgs[0].kind === NodeKind.Identifier;
	assert (d.typExprArgs[0].data as IdentifierData).name === "U";
}

// ===== mapTypeToAst tests — Day 5 (Alias peel + cycle handling) =====

function makeAliasType(name: string, inner: Type): Type {
	const t = makePrimType(TypeKind.Alias);
	t.typeName = name;
	t.typeReturn = inner;
	return t;
}

test "mapTypeToAst — Alias peels transparently to inner primitive" {
	const loc = makeLoc(1, 0);
	const out = mapTypeToAst(makeAliasType("MyInt", makePrimType(TypeKind.Int32)), loc);
	assert out.kind === NodeKind.Identifier;
	assert (out.data as IdentifierData).name === "int32";
}

test "mapTypeToAst — Alias peels through to inner Struct" {
	const loc = makeLoc(1, 0);
	const inner = makeStructType("User", ["id"], [makePrimType(TypeKind.Int32)]);
	const out = mapTypeToAst(makeAliasType("UserAlias", inner), loc);
	assert out.kind === NodeKind.TypeObject;
	const d = out.data as TypeObjectData;
	assert d.typExprFieldNames[0] === "id";
}

test "mapTypeToAst — Alias with null typeReturn falls through to fallback" {
	const loc = makeLoc(1, 0);
	const t = makePrimType(TypeKind.Alias);
	t.typeName = "Bare";
	const out = mapTypeToAst(t, loc);
	assert out.kind === NodeKind.Identifier;
	assert (out.data as IdentifierData).name === "Bare";
}

test "mapTypeToAst — self-aliased Type (`type X = X`) terminates via cycle break" {
	const loc = makeLoc(1, 0);
	const t = makePrimType(TypeKind.Alias);
	t.typeName = "Loop";
	t.typeReturn = t;  // self-alias — would stack-overflow without visited gate
	const out = mapTypeToAst(t, loc);
	assert out.kind === NodeKind.Identifier;
	assert (out.data as IdentifierData).name === "Loop";
}

test "mapTypeToAst — chained alias (A → B → int32) peels through both layers" {
	const loc = makeLoc(1, 0);
	const aliasB = makeAliasType("B", makePrimType(TypeKind.Int32));
	const aliasA = makeAliasType("A", aliasB);
	const out = mapTypeToAst(aliasA, loc);
	assert out.kind === NodeKind.Identifier;
	assert (out.data as IdentifierData).name === "int32";
}

test "mapTypeToAst — self-referential Struct (Tree<children: Tree[]>) terminates via cycle break" {
	const loc = makeLoc(1, 0);
	const tree = makePrimType(TypeKind.Struct);
	tree.typeName = "Tree";
	tree.typeNames = ["children"];
	tree.typeChildren = [makeArrayType(TypeKind.Array, tree, 0)];  // Tree[] containing Tree itself
	const out = mapTypeToAst(tree, loc);
	assert out.kind === NodeKind.TypeObject;
	const d = out.data as TypeObjectData;
	assert d.typExprFieldNames[0] === "children";
	// Tree[] field: TypeArray with element being the cycle-break Identifier
	assert d.typExprFieldTypes[0].kind === NodeKind.TypeArray;
	const arrData = d.typExprFieldTypes[0].data as TypeArrayData;
	assert arrData.typExprElement.kind === NodeKind.Identifier;
	assert (arrData.typExprElement.data as IdentifierData).name === "Tree";
}

test "mapTypeToAst — mutually-recursive Structs (A.b: B, B.a: A) terminate" {
	const loc = makeLoc(1, 0);
	const a = makePrimType(TypeKind.Struct);
	const b = makePrimType(TypeKind.Struct);
	a.typeName = "A";
	a.typeNames = ["b"];
	a.typeChildren = [b];
	b.typeName = "B";
	b.typeNames = ["a"];
	b.typeChildren = [a];
	const out = mapTypeToAst(a, loc);
	assert out.kind === NodeKind.TypeObject;
	const aData = out.data as TypeObjectData;
	assert aData.typExprFieldTypes[0].kind === NodeKind.TypeObject;
	const bData = aData.typExprFieldTypes[0].data as TypeObjectData;
	// B.a: should be cycle-broken to Identifier("A")
	assert bData.typExprFieldTypes[0].kind === NodeKind.Identifier;
	assert (bData.typExprFieldTypes[0].data as IdentifierData).name === "A";
}

test "mapTypeToAst — sibling references to same Struct expand independently (not a cycle)" {
	const loc = makeLoc(1, 0);
	const shared = makeStructType("Shared", ["v"], [makePrimType(TypeKind.Int32)]);
	// outer { left: Shared, right: Shared } — siblings, not ancestors
	const outer = makeStructType("Outer", ["left", "right"], [shared, shared]);
	const out = mapTypeToAst(outer, loc);
	const d = out.data as TypeObjectData;
	assert d.typExprFieldTypes[0].kind === NodeKind.TypeObject;
	assert d.typExprFieldTypes[1].kind === NodeKind.TypeObject;  // both fully expanded
}

// ===== mapTypeToAst tests — Day 6 (Union → TypeUnion) =====

function makeUnionType(variants: Type[]): Type {
	const t = makePrimType(TypeKind.Union);
	t.typeChildren = variants;
	return t;
}

test "mapTypeToAst — Union of primitives emits TypeUnion with all members" {
	const loc = makeLoc(1, 0);
	const t = makeUnionType([makePrimType(TypeKind.String), makePrimType(TypeKind.Int32)]);
	const out = mapTypeToAst(t, loc);
	assert out.kind === NodeKind.TypeUnion;
	const d = out.data as TypeUnionData;
	assert d.typExprMembers.length === 2;
	assert (d.typExprMembers[0].data as IdentifierData).name === "string";
	assert (d.typExprMembers[1].data as IdentifierData).name === "int32";
}

test "mapTypeToAst — Union with Struct member recurses into TypeObject" {
	const loc = makeLoc(1, 0);
	const struct = makeStructType("User", ["id"], [makePrimType(TypeKind.Int32)]);
	const t = makeUnionType([makePrimType(TypeKind.Null), struct]);
	const out = mapTypeToAst(t, loc);
	const d = out.data as TypeUnionData;
	assert d.typExprMembers.length === 2;
	assert (d.typExprMembers[0].data as IdentifierData).name === "null";
	assert d.typExprMembers[1].kind === NodeKind.TypeObject;
}

test "mapTypeToAst — single-variant Union emits TypeUnion with one member" {
	const loc = makeLoc(1, 0);
	const out = mapTypeToAst(makeUnionType([makePrimType(TypeKind.Boolean)]), loc);
	assert out.kind === NodeKind.TypeUnion;
	const d = out.data as TypeUnionData;
	assert d.typExprMembers.length === 1;
	assert (d.typExprMembers[0].data as IdentifierData).name === "boolean";
}

test "mapTypeToAst — empty Union (degenerate) emits TypeUnion with empty members" {
	const loc = makeLoc(1, 0);
	const out = mapTypeToAst(makeUnionType([]), loc);
	assert out.kind === NodeKind.TypeUnion;
	const d = out.data as TypeUnionData;
	assert d.typExprMembers.length === 0;
}

test "mapTypeToAst — nested Union<Union<...>, T> recurses correctly" {
	const loc = makeLoc(1, 0);
	const inner = makeUnionType([makePrimType(TypeKind.String), makePrimType(TypeKind.Int32)]);
	const outer = makeUnionType([inner, makePrimType(TypeKind.Null)]);
	const out = mapTypeToAst(outer, loc);
	const d = out.data as TypeUnionData;
	assert d.typExprMembers.length === 2;
	assert d.typExprMembers[0].kind === NodeKind.TypeUnion;
	const innerData = d.typExprMembers[0].data as TypeUnionData;
	assert innerData.typExprMembers.length === 2;
	assert (d.typExprMembers[1].data as IdentifierData).name === "null";
}

// ===== mapTypeToAst tests — Day 7 (Ref/Ptr/Borrow/Sink/Lent/Var/Distinct → TypeGeneric) =====

function makeModifierType(kind: TypeKind, inner: Type): Type {
	const t = makePrimType(kind);
	t.typeReturn = inner;
	return t;
}

test "mapTypeToAst — Ref<T> emits TypeGeneric(\"Ref\", [T])" {
	const out = mapTypeToAst(makeModifierType(TypeKind.Ref, makePrimType(TypeKind.Int32)), makeLoc(1, 0));
	assert out.kind === NodeKind.TypeGeneric;
	const d = out.data as TypeGenericData;
	assert (d.typExprBase.data as IdentifierData).name === "Ref";
	assert d.typExprArgs.length === 1;
	assert (d.typExprArgs[0].data as IdentifierData).name === "int32";
}

test "mapTypeToAst — Ptr<T> emits TypeGeneric(\"Ptr\", [T])" {
	const out = mapTypeToAst(makeModifierType(TypeKind.Ptr, makePrimType(TypeKind.Int32)), makeLoc(1, 0));
	assert out.kind === NodeKind.TypeGeneric;
	const d = out.data as TypeGenericData;
	assert (d.typExprBase.data as IdentifierData).name === "Ptr";
	assert (d.typExprArgs[0].data as IdentifierData).name === "int32";
}

test "mapTypeToAst — Borrow<T> emits TypeGeneric(\"Borrow\", [T])" {
	const out = mapTypeToAst(makeModifierType(TypeKind.Borrow, makePrimType(TypeKind.Int32)), makeLoc(1, 0));
	assert out.kind === NodeKind.TypeGeneric;
	const d = out.data as TypeGenericData;
	assert (d.typExprBase.data as IdentifierData).name === "Borrow";
	assert (d.typExprArgs[0].data as IdentifierData).name === "int32";
}

test "mapTypeToAst — Sink<T> emits TypeGeneric(\"Sink\", [T])" {
	const out = mapTypeToAst(makeModifierType(TypeKind.Sink, makePrimType(TypeKind.Int32)), makeLoc(1, 0));
	assert out.kind === NodeKind.TypeGeneric;
	const d = out.data as TypeGenericData;
	assert (d.typExprBase.data as IdentifierData).name === "Sink";
	assert (d.typExprArgs[0].data as IdentifierData).name === "int32";
}

test "mapTypeToAst — Lent<T> emits TypeGeneric(\"Lent\", [T])" {
	const out = mapTypeToAst(makeModifierType(TypeKind.Lent, makePrimType(TypeKind.Int32)), makeLoc(1, 0));
	assert out.kind === NodeKind.TypeGeneric;
	const d = out.data as TypeGenericData;
	assert (d.typExprBase.data as IdentifierData).name === "Lent";
	assert (d.typExprArgs[0].data as IdentifierData).name === "int32";
}

test "mapTypeToAst — Var<T> emits TypeGeneric(\"Var\", [T])" {
	const out = mapTypeToAst(makeModifierType(TypeKind.Var, makePrimType(TypeKind.Int32)), makeLoc(1, 0));
	assert out.kind === NodeKind.TypeGeneric;
	const d = out.data as TypeGenericData;
	assert (d.typExprBase.data as IdentifierData).name === "Var";
	assert (d.typExprArgs[0].data as IdentifierData).name === "int32";
}

test "mapTypeToAst — Distinct<T> emits TypeGeneric(\"Distinct\", [T])" {
	const out = mapTypeToAst(makeModifierType(TypeKind.Distinct, makePrimType(TypeKind.Int32)), makeLoc(1, 0));
	assert out.kind === NodeKind.TypeGeneric;
	const d = out.data as TypeGenericData;
	assert (d.typExprBase.data as IdentifierData).name === "Distinct";
	assert (d.typExprArgs[0].data as IdentifierData).name === "int32";
}

test "mapTypeToAst — nested modifier Ref<Ptr<T>> recurses through both layers" {
	const loc = makeLoc(1, 0);
	const inner = makeModifierType(TypeKind.Ptr, makePrimType(TypeKind.Int32));
	const outer = makeModifierType(TypeKind.Ref, inner);
	const out = mapTypeToAst(outer, loc);
	assert out.kind === NodeKind.TypeGeneric;
	const d = out.data as TypeGenericData;
	assert (d.typExprBase.data as IdentifierData).name === "Ref";
	assert d.typExprArgs[0].kind === NodeKind.TypeGeneric;
	const innerData = d.typExprArgs[0].data as TypeGenericData;
	assert (innerData.typExprBase.data as IdentifierData).name === "Ptr";
	assert (innerData.typExprArgs[0].data as IdentifierData).name === "int32";
}

test "mapTypeToAst — Ref<Struct> wraps TypeObject inside TypeGeneric" {
	const loc = makeLoc(1, 0);
	const struct = makeStructType("User", ["id"], [makePrimType(TypeKind.Int32)]);
	const out = mapTypeToAst(makeModifierType(TypeKind.Ref, struct), loc);
	assert out.kind === NodeKind.TypeGeneric;
	const d = out.data as TypeGenericData;
	assert (d.typExprBase.data as IdentifierData).name === "Ref";
	assert d.typExprArgs[0].kind === NodeKind.TypeObject;
}

test "mapTypeToAst — modifier with null inner falls through to <null> sentinel" {
	const loc = makeLoc(1, 0);
	const t = makePrimType(TypeKind.Ref);
	// typeReturn left null
	const out = mapTypeToAst(t, loc);
	assert out.kind === NodeKind.TypeGeneric;
	const d = out.data as TypeGenericData;
	assert (d.typExprBase.data as IdentifierData).name === "Ref";
	assert (d.typExprArgs[0].data as IdentifierData).name === "<null>";
}

// ===== Day 8 tests — nodeToValue emits `nodeType` field for typed Nodes =====

test "nodeToValue — Node with primitive nodeType emits Identifier under \"nodeType\" field" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const ident = createNodeAt(NodeKind.Identifier, { name: "x" }, loc);
	ident.nodeType = makePrimType(TypeKind.Int32);
	const v = nodeToValue(ident, objH, arrH);
	assert v.kind === RaiserValueKind.Object;
	const typeFieldVal = heapObjectGetField(objH, v.intVal, "nodeType");
	assert typeFieldVal.kind === RaiserValueKind.Object;
	// The serialized type-AST is an Identifier — read its "name" field.
	const nameVal = heapObjectGetField(objH, typeFieldVal.intVal, "name");
	assert nameVal.kind === RaiserValueKind.String;
	assert nameVal.strVal === "int32";
	// And its kind is NodeKind.Identifier.
	const kindVal = heapObjectGetField(objH, typeFieldVal.intVal, "kind");
	assert kindVal.kind === RaiserValueKind.Int;
	assert kindVal.intVal === NodeKind.Identifier as number;
}

test "nodeToValue — Node with null nodeType skips emitting the field" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const ident = createNodeAt(NodeKind.Identifier, { name: "x" }, loc);
	// nodeType left null
	const v = nodeToValue(ident, objH, arrH);
	assert v.kind === RaiserValueKind.Object;
	const typeFieldVal = heapObjectGetField(objH, v.intVal, "nodeType");
	// Field absent → heap returns Nil
	assert typeFieldVal.kind === RaiserValueKind.Nil;
}

test "nodeToValue — Node with Struct nodeType emits TypeObject with field info" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const struct = makeStructType("User", ["id", "name"], [makePrimType(TypeKind.Int32), makePrimType(TypeKind.String)]);
	const ident = createNodeAt(NodeKind.Identifier, { name: "u" }, loc);
	ident.nodeType = struct;
	const v = nodeToValue(ident, objH, arrH);
	const typeFieldVal = heapObjectGetField(objH, v.intVal, "nodeType");
	assert typeFieldVal.kind === RaiserValueKind.Object;
	const kindVal = heapObjectGetField(objH, typeFieldVal.intVal, "kind");
	assert kindVal.intVal === NodeKind.TypeObject as number;
}

test "nodeToValue — TypeObject heap dispatch emits typExprFieldDecorators array (V2)" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const renameDec = createNodeAt(NodeKind.CallExpr, {
		callee: createNodeAt(NodeKind.Identifier, { name: "rename" }, loc),
		arguments: [createNodeAt(NodeKind.StringLiteral, { value: "_id" }, loc)],
	}, loc);
	const t = makeClassWithDecoratedFields("Doc", ["id", "name"], [[renameDec], []]);
	const ident = createNodeAt(NodeKind.Identifier, { name: "d" }, loc);
	ident.nodeType = t;
	const v = nodeToValue(ident, objH, arrH);
	const typeVal = heapObjectGetField(objH, v.intVal, "nodeType");
	assert typeVal.kind === RaiserValueKind.Object;
	const decorsVal = heapObjectGetField(objH, typeVal.intVal, "typExprFieldDecorators");
	// Outer array — 2 entries (one per field)
	assert decorsVal.kind === RaiserValueKind.Array;
	assert heapArrayLen(arrH, decorsVal.intVal) === 2;
	// First inner array — 1 decorator (rename CallExpr)
	const firstInner = heapArrayGet(arrH, decorsVal.intVal, 0);
	assert firstInner.kind === RaiserValueKind.Array;
	assert heapArrayLen(arrH, firstInner.intVal) === 1;
	// Second inner array — empty (name has no decorators)
	const secondInner = heapArrayGet(arrH, decorsVal.intVal, 1);
	assert heapArrayLen(arrH, secondInner.intVal) === 0;
}

test "nodeToValue — synthesized type-AST node has no nested nodeType (recursion terminates)" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const ident = createNodeAt(NodeKind.Identifier, { name: "x" }, loc);
	ident.nodeType = makePrimType(TypeKind.Int32);
	const v = nodeToValue(ident, objH, arrH);
	const typeFieldVal = heapObjectGetField(objH, v.intVal, "nodeType");
	// The synthesized Identifier (the type AST) should NOT have its own "nodeType" field.
	const innerTypeField = heapObjectGetField(objH, typeFieldVal.intVal, "nodeType");
	assert innerTypeField.kind === RaiserValueKind.Nil;
}

test "nodeToValue — self-referential nodeType (Tree) terminates via cycle break" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const tree = makePrimType(TypeKind.Struct);
	tree.typeName = "Tree";
	tree.typeNames = ["children"];
	tree.typeChildren = [makeArrayType(TypeKind.Array, tree, 0)];
	const ident = createNodeAt(NodeKind.Identifier, { name: "root" }, loc);
	ident.nodeType = tree;
	// Must not stack-overflow — Day 5 visited barrier breaks the cycle inside mapTypeToAst.
	const v = nodeToValue(ident, objH, arrH);
	const typeFieldVal = heapObjectGetField(objH, v.intVal, "nodeType");
	assert typeFieldVal.kind === RaiserValueKind.Object;
	const kindVal = heapObjectGetField(objH, typeFieldVal.intVal, "kind");
	assert kindVal.intVal === NodeKind.TypeObject as number;
}

test "valueToNode — drops nodeType field (forward-only design)" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const ident = createNodeAt(NodeKind.Identifier, { name: "x" }, loc);
	ident.nodeType = makePrimType(TypeKind.Int32);
	const v = nodeToValue(ident, objH, arrH);
	const back = valueToNode(v, objH, arrH, loc);
	assert back.kind === NodeKind.Identifier;
	assert (back.data as IdentifierData).name === "x";
	assert back.nodeType === null;  // forward-only: reverse path leaves nodeType null
}

test "nodeToValue — child Nodes' nodeType cascades through dispatch" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const left = createNodeAt(NodeKind.Identifier, { name: "a" }, loc);
	left.nodeType = makePrimType(TypeKind.Int32);
	const right = createNodeAt(NodeKind.NumberLiteral, { value: 1, isFloat: false }, loc);
	right.nodeType = makePrimType(TypeKind.Int32);
	const expr = createNodeAt(NodeKind.BinaryExpr, { operator: "+", left, right }, loc);
	expr.nodeType = makePrimType(TypeKind.Int32);
	const v = nodeToValue(expr, objH, arrH);
	// Outer BinaryExpr has nodeType
	const outerType = heapObjectGetField(objH, v.intVal, "nodeType");
	assert outerType.kind === RaiserValueKind.Object;
	// Left child has its own nodeType
	const leftVal = heapObjectGetField(objH, v.intVal, "left");
	assert leftVal.kind === RaiserValueKind.Object;
	const leftType = heapObjectGetField(objH, leftVal.intVal, "nodeType");
	assert leftType.kind === RaiserValueKind.Object;
	// Right child likewise
	const rightVal = heapObjectGetField(objH, v.intVal, "right");
	const rightType = heapObjectGetField(objH, rightVal.intVal, "nodeType");
	assert rightType.kind === RaiserValueKind.Object;
}

// ===== Day 9 tests — nodeToValue emits `resolvedSym` for bound Nodes =====

function makeSymbol(name: string, kind: SymbolKind): Symbol {
	return {
		name,
		nameId: 0 as int32,
		symbolKind: kind,
		symbolType: makePrimType(TypeKind.Unknown),
		state: SymbolState.Checked,
		location: makeLoc(1, 0),
		declNode: null as unknown as Node,
		overloads: [],
		nativeName: "",
		builtinKind: "",
		symFlags: 0 as int32,
		defaultParams: [],
		modulePath: "",
		originalName: "",
		headerPath: "",
		jsModulePath: "",
		overloadIdx: 0 as int32,
		mutatedParams: 0 as int32,
		staticFields: [],
	};
}

test "nodeToValue — Node with resolvedSym emits { name, kind } object" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const ident = createNodeAt(NodeKind.Identifier, { name: "myVar" }, loc);
	ident.resolvedSym = makeSymbol("myVar", SymbolKind.Variable);
	const v = nodeToValue(ident, objH, arrH);
	const symVal = heapObjectGetField(objH, v.intVal, "resolvedSym");
	assert symVal.kind === RaiserValueKind.Object;
	const nameVal = heapObjectGetField(objH, symVal.intVal, "name");
	assert nameVal.kind === RaiserValueKind.String;
	assert nameVal.strVal === "myVar";
	const kindVal = heapObjectGetField(objH, symVal.intVal, "kind");
	assert kindVal.kind === RaiserValueKind.Int;
	assert kindVal.intVal === SymbolKind.Variable as number;
}

test "nodeToValue — Node without resolvedSym skips emitting the field" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const ident = createNodeAt(NodeKind.Identifier, { name: "x" }, loc);
	// resolvedSym left as null cast
	const v = nodeToValue(ident, objH, arrH);
	const symVal = heapObjectGetField(objH, v.intVal, "resolvedSym");
	assert symVal.kind === RaiserValueKind.Nil;
}

test "nodeToValue — different SymbolKinds preserved correctly" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const ident = createNodeAt(NodeKind.Identifier, { name: "fn" }, loc);
	ident.resolvedSym = makeSymbol("fn", SymbolKind.Function);
	const v = nodeToValue(ident, objH, arrH);
	const symVal = heapObjectGetField(objH, v.intVal, "resolvedSym");
	const kindVal = heapObjectGetField(objH, symVal.intVal, "kind");
	assert kindVal.intVal === SymbolKind.Function as number;
}

test "valueToNode — drops resolvedSym field (forward-only design)" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const ident = createNodeAt(NodeKind.Identifier, { name: "x" }, loc);
	ident.resolvedSym = makeSymbol("x", SymbolKind.Variable);
	const v = nodeToValue(ident, objH, arrH);
	const back = valueToNode(v, objH, arrH, loc);
	assert back.kind === NodeKind.Identifier;
	assert (back.data as IdentifierData).name === "x";
	// Forward-only: reverse path leaves resolvedSym as the null-cast sentinel.
	assert back.resolvedSym === null;
}

test "nodeToValue — Symbol with empty name still emits object with empty string" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const ident = createNodeAt(NodeKind.Identifier, { name: "anon" }, loc);
	ident.resolvedSym = makeSymbol("", SymbolKind.Parameter);
	const v = nodeToValue(ident, objH, arrH);
	const symVal = heapObjectGetField(objH, v.intVal, "resolvedSym");
	const nameVal = heapObjectGetField(objH, symVal.intVal, "name");
	assert nameVal.strVal === "";
}

test "nodeToValue — child Nodes' resolvedSym cascades through dispatch" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const left = createNodeAt(NodeKind.Identifier, { name: "a" }, loc);
	left.resolvedSym = makeSymbol("a", SymbolKind.Variable);
	const right = createNodeAt(NodeKind.Identifier, { name: "b" }, loc);
	right.resolvedSym = makeSymbol("b", SymbolKind.Function);
	const expr = createNodeAt(NodeKind.BinaryExpr, { operator: "+", left, right }, loc);
	const v = nodeToValue(expr, objH, arrH);
	const leftVal = heapObjectGetField(objH, v.intVal, "left");
	const leftSym = heapObjectGetField(objH, leftVal.intVal, "resolvedSym");
	assert leftSym.kind === RaiserValueKind.Object;
	const leftKind = heapObjectGetField(objH, leftSym.intVal, "kind");
	assert leftKind.intVal === SymbolKind.Variable as number;
	const rightVal = heapObjectGetField(objH, v.intVal, "right");
	const rightSym = heapObjectGetField(objH, rightVal.intVal, "resolvedSym");
	const rightKind = heapObjectGetField(objH, rightSym.intVal, "kind");
	assert rightKind.intVal === SymbolKind.Function as number;
}
