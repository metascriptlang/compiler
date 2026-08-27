// std/meta/node — AST Node definitions for MetaScript
// Source of truth for Node, Type, Symbol, and all AST data types.
// Used by both the compiler (via src/ast/node.ms re-export) and macro authors (via std/meta).

import { Token } from "./token";

// ===== TypeKind Enum =====

export enum TypeKind {
	Number, String, Boolean, Void, Char, Null, Pending, Never,
	Int8, Int16, Int32, Int64, Uint8, Uint16, Uint32, Uint64, Float32, Float64,
	Struct, Array, SizedArray, Span, Function, Tuple, CString,
	GenericParam, GenericInstance,
	Ref, Ptr, Borrow,
	Sink, Lent, Var,
	TypeReference, Union, Enum, Result,
	// REPROMISE T2: legacy `Promise` variant removed. All awaitables share the
	// single surface type `Promise<T>`, represented as GenericInstance. Origin
	// (plain async vs spawn-affine) is distinguished by AwaitableAffine +
	// AwaitableScopeBound flag bits on typeFlags.
	Distinct,
	Error,
	StringLiteral,
	EnumLiteral,
	Conditional,
	// Added by the peelThrough work in src/checker/types.ms — transparent type
	// alias wrapper that peelThrough strips when PEEL_ALIAS mask is set.
	Alias,
	// Boolean literal type (TypeScript parity): `true` and `false` as distinct
	// types. Required for discriminated union narrowing on boolean discriminants
	// (e.g. `type Result<T, E> = { ok: true, value: T } | { ok: false, error: E }`).
	// Codegen lowers to MS_BOOL with the literal value.
	BooleanLiteral,
	// Reference parity (tyVarargs): marker wrapping a rest parameter's array type
	// (e.g. `...args: string[]` → Varargs(Array(string))). Source of truth for
	// rest detection — replaces the legacy "..." name-prefix encoding. The
	// wrapper is transparent: typeChildren[0] holds the user-written array type,
	// codegen + isAssignable peel it via unwrapVarargs.
	Varargs,
	// Non-owning link to a managed T: the pointee is reference-counted but this
	// slot does not participate — lifecycle hooks skip it. A wrapper type rather
	// than a declaration annotation because interface fields are parallel string
	// arrays with no symbol to carry a flag. Transparent: skipModifier peels it.
	Cursor,
	Unknown,
	None,
	Inferred,
}

// ===== Calling Convention =====
export enum CallingConvention {
	CcDefault,
	CcClosure,
	CcInline,
	CcNoInline,
}

// ===== Type Flags =====
export enum TypeFlag {
	IsStruct = 1,                // bit 0
	IsMaybe = 16,                // bit 4
	HasAsgn = 32,                // bit 5
	AwaitableAffine = 64,        // bit 6 — PARALOCK affine (spawn-origin Promise)
	AwaitableScopeBound = 128,   // bit 7 — PARALOCK R3/E4 (cannot escape creating scope)
	HasInheritedFields = 256,    // bit 8 — class has flattened parent fields (suppresses DRC parent-call)
	Substituting = 1048576,      // bit 20 (high to avoid SizedArray size collision)
	IsAtomic = 2097152,          // bit 21 (high, like Substituting — Arc<T> atomic-rc marker on a Ref; never on SizedArray size / Function minArity)
	DuVariant = 4194304,         // bit 22 (high, same rule) — INLINE (nameless) union-variant payload struct; lifecycle owned by the DU machinery, analyzer defers (classify → no RC)
	OpenClass = 8388608,         // bit 23 (high, same rule) — class is extended (non-final): canFormAcycle returns true unconditionally, the Nim tfFinal rule (types.nim:436-438). Stamped on the PARENT struct in resolveClass; a CBase-typed field may point at a subclass that closes a back-edge
	BrandWiden = 16777216,       // bit 24 (high, same rule) — TS branded primitive (`Prim & { __brand }`): Distinct that widens implicitly to its base; erased to base after check (brandErase)
}

// ===== Attached Lifecycle Ops =====
export enum AttachedOp {
	AttachedWasMoved,
	AttachedDestructor,
	AttachedAsgn,
	AttachedDup,
	AttachedSink,
	AttachedTrace,
}

// ===== Type =====
//
// Name fields carry MULTIPLE roles — read carefully:
//   typeName       — (1) identity key for attachedOps lookup and hook-name derivation,
//                    (2) C struct name at codegen, (3) display/error-message text.
//                    Empty for anonymous/primitive types. Shared across specializations
//                    of the same generic body (e.g. Map<int,X> and Map<str,Y> both have
//                    typeName="Map") — callers that need per-specialization uniqueness
//                    must use typeChildren alongside.
//   typeNames      — member/child NAMES (field, parameter, variant, tuple-element names).
//                    Parallel to typeChildren. Plural spelling despite proximity to the
//                    singular typeName — treat as an independent array, not a list of
//                    typeName values.
//   typeChildren   — member/child TYPES, parallel to typeNames. Semantics per TypeKind:
//                    Struct/Interface → field types; Function → param types;
//                    Union → variant types; Tuple → element types; GenericInstance → type args.
//   typeReturn     — inner/wrapped type. Semantics per TypeKind:
//                    Ref/Ptr/Borrow/Var/Sink/Lent → pointee type;
//                    Array/SizedArray/Span → element type;
//                    Function → return type; Distinct → underlying type.
//                    NOT restricted to function returns — name is historical.
//   typeExtra      — catch-all secondary type slot. Used for:
//                    Struct with generic params → generic body; Array → element (legacy);
//                    GenericInstance → monomorphized concrete body; TypeAlias → aliased type.
//                    Consult per-TypeKind documentation before use.
//   typeFlags      — bitset (TypeFlag.HasAsgn, IsStruct, AwaitableAffine, ...) — propagated
//                    bottom-up by propagateToOwner when building parent types.
//   attachedOps    — hook function names (index = AttachedOp enum: Destroy/Copy/Sink/...).
//                    Populated by destructorLifting. Inline per-Type; see setAttachedOp /
//                    getAttachedOp in src/checker/types.ms.
//   sym            — back-pointer to the declaring Symbol (Class/Interface/Enum decls).
export class Type {
	kind: TypeKind;
	typeName: string;
	typeNames: string[];
	typeChildren: Type[];
	typeReturn: Type | null;
	typeExtra: Type | null;
	typeFlags: int32;
	callConv: CallingConvention;
	attachedOps: string[];
	sym: Symbol | null;
}

// ===== Symbol Kind =====

export enum SymbolKind {
	Variable,
	Function,
	Class,
	Interface,
	TypeAlias,
	Enum,
	Parameter,
	Property,
	Method,
	EnumMember,
	Struct,
	Module,
	Actor,
	Macro,
}

// ===== Symbol State (Lifecycle) =====

export enum SymbolState {
	Hollow,    // Registered only (Pass 1)
	Shaping,   // Currently resolving signature (Pass 2 re-entrancy guard)
	Shaped,    // Signature (params/return/fields) resolved
	Checking,  // Currently checking body (Pass 3)
	Checked,   // Fully validated
}

// ===== Symbol =====

export class Symbol {
	name: string;
	nameId: int32;
	symbolKind: SymbolKind;
	symbolType: Type;
	state: SymbolState;
	location: SourceLocation;
	declNode: Node;
	overloads: Symbol[];
	nativeName: string;
	builtinKind: string;
	symFlags: int32;
	defaultParams: Node[];
	modulePath: string;
	originalName: string;  // Original declared name, used for C mangling when imported with alias
	headerPath: string;    // @include header for this extern symbol
	jsModulePath: string;  // @import JS module for this extern symbol
	overloadIdx: int32;    // Index within overload set (0=primary, 1+=overload)
	mutatedParams: int32;  // Bitfield: bit i = param i is mutated in body (gates const-ptr promotion)
	staticFields: Symbol[];  // Static properties (only for class symbols)
	duVariantSlot: int32;  // Narrowed DU field access: 0 = none, N = union variant N-1 (checker stamps on the property sym; C codegen routes .v<N-1>)
}

// ===== Node Flags (Standard parity: TNodeFlags) =====
// Bitfield on Node.flags — tracks processing state and optimization hints.
export enum NodeFlag {
	None = 0,
	Sem = 1,            // semantic pass done (skip re-checking)
	Transf = 2,         // transform pass done (skip re-transforming)
	LL = 4,             // lambda lifting done
	LastRead = 8,       // DRC: this is the last read of a variable
	FirstWrite = 16,    // DRC: this is the first write to a variable
	PreventCG = 32,     // skip in codegen
	FromTemplate = 64,  // generated by template/macro expansion
	Closure = 128,      // ObjectLiteral is a closure pair {fn, env}
	Cursor = 256,       // VariableDecl is a borrow (for-of binding) — skip RC destroy (reference: cursor flag)
	ExtCall = 512,      // checker: this CallExpr is an extension method call (UFCS)
	ExtStatic = 1024,   // checker: this extension call is static (no receiver prepend)
	ExportDefault = 2048, // parser: export default declaration
	WasAsync = 4096,      // transform: function was async before asyncDesugar rewrote to generator
	ExternC = 8192,       // parser: extern interface — type defined in C header, skip codegen emission
	BoundSym = 16384,     // macro bindSym: resolvedSym pre-bound in the macro's module — checker must not re-lookup
	Converter = 32768,    // parser: MacroDecl is a converter — compiler-invoked at settled type boundaries
	StaticStorage = 65536, // parser: VariableDecl declared `static` inside a body — storage at module scope (reference: global storage flag)
}

// ===== Node Kind Enum =====

export enum NodeKind {
	// Literals
	NumberLiteral, StringLiteral, BooleanLiteral, NullLiteral, BigIntLiteral, RegexLiteral,
	// Identifiers
	Identifier,
	// Expressions
	BinaryExpr, UnaryExpr, UpdateExpr, CallExpr, MemberExpr, ArrayAccess,
	ObjectLiteral, ArrayLiteral, ArrowFunction, FunctionExpr, TypeAssertion,
	ConditionalExpr, SpreadExpr, NewExpr,
	TryExpr, MatchExpr, MatchCase,
	AwaitExpr, YieldExpr, MoveExpr, OutExpr,
	HiddenDeref, HiddenAddr,
	HiddenStdConv, HiddenSubConv,
	TypeAnnotation,
	// Patterns
	ArrayPattern, ObjectPattern, ObjectPatternProp, DestructuringDecl,
	// Statements
	VariableDecl, IfStmt, WhileStmt, ForStmt, ForOfStmt, ForInStmt, BlockStmt,
	ExprStmt, ReturnStmt, BreakStmt, ContinueStmt, FunctionDecl,
	DoWhileStmt, SwitchStmt, SwitchCase,
	UnreachableStmt, MatchStmt,
	// Declarations
	ImportDecl, ExportDecl, TypeAliasDecl, EnumDecl, InterfaceDecl, StructDecl,
	ClassDecl, PropertyDecl, MethodDecl, ConstructorDecl,
	// Error handling
	ThrowStmt, TryCatchStmt,
	// Decorators
	MacroInvocation, DecoratedDecl,
	// Other
	DeferStmt,
	// Testing
	TestDecl, AssertStmt,
	// Extern / Macro / Quote / Comptime
	ExternDecl, MacroDecl, QuoteExpr, ComptimeBlock,
	// Self-hosting primitives
	SizeofExpr,
	// Type expression nodes (reuse Identifier for leaf types — standard parity)
	TypeGeneric, TypeArray, TypeUnion, TypeFunction, TypeObject,
	// Program root
	Program,
	// Actor (appended at end to preserve enum discriminant ordering)
	ActorDecl,
	// SERIALIZE A2: macro multi-decl emission. Splices into parent stmt array.
	SpliceMany,
	// Type expression node — intersection types (T & U). Appended at end
	// to preserve enum discriminant ordering. Erasure-tier: resolver
	// collapses to first operand at type-checking time; downstream sees
	// the erased type. See docs/LANG.md §5.3.
	TypeIntersection,
	// JSX (appended at end to preserve enum discriminant ordering). All 6 kinds
	// are compile-time only — erased by a consuming macro before codegen.
	// See docs/LANG-JSX.md for spec, docs/JSX-ROADMAP.md for phased plan.
	JSXElement, JSXFragment, JSXText,
	JSXExpressionContainer, JSXAttribute, JSXSpreadAttribute,
}

// ===== Declaration Kind Enum =====

export enum DeclKind {
	Const,
	Let,
	Var,
}

export enum ExternKind {
	Invalid,
	Function,
	Class,
	Interface,
	Struct,
	Const,
	Var,
	Let,
	Type,
	Enum,
	Macro,
}

// ===== Source Location =====

export interface SourceLocation {
	line: int32;
	column: int32;
	endLine: int32;    // 0 = unknown (falls back to line)
	endColumn: int32;  // 0 = unknown (falls back to column + 1)
}

export function makeLoc(line: number, column: number): SourceLocation {
	return { line: line as int32, column: column as int32, endLine: 0 as int32, endColumn: 0 as int32 };
}

export function makeLocRange(line: int32, column: int32, endLine: int32, endColumn: int32): SourceLocation {
	return { line, column, endLine, endColumn };
}

// ===== Node Data (Discriminated Union) =====
// Each variant has structurally unique field names for distinct anonymous structs

export type NodeData =
	// Literal variants
	| { value: number, isFloat: boolean, intVal: int64, outOfRangeText: string, isBitPattern: boolean }           // NumberLiteral
	| { value: string }                                            // StringLiteral
	| { boolValue: boolean }                                       // BooleanLiteral
	| { nullPlaceholder: boolean }                                 // NullLiteral (always true)
	| { bigintValue: string }                                      // BigIntLiteral ("123n")
	| { regexPattern: string }                                     // RegexLiteral ("/pattern/flags")
	// Identifier
	| { name: string }                                             // Identifier
	// Expression variants
	| { operator: string, left: Node, right: Node }                // BinaryExpr
	| { unaryOp: string, operand: Node }                           // UnaryExpr
	| { updateOp: string, updateArg: Node, isPrefix: boolean }     // UpdateExpr (i++, ++i)
	| { callee: Node, arguments: Node[], isDirectCall: boolean, resolvedOverloadIdx: number }  // CallExpr
	| { object: Node, property: string, isOptional: boolean }      // MemberExpr
	| { array: Node, index: Node }                                 // ArrayAccess
	| { properties: Node[], keys: string[], keyLocations: SourceLocation[] } // ObjectLiteral
	| { elements: Node[] }                                         // ArrayLiteral
	| { arrowParams: string[], arrowParamTypes: string[], arrowBody: Node, arrowFlags: string, arrowReturnType: string, arrowDefaults: (Node | null)[] } // ArrowFunction
	| { funcExprParams: string[], funcExprParamTypes: string[], funcExprBody: Node, funcExprFlags: string, funcExprReturnType: string } // FunctionExpr
	| { asExpr: Node, asType: string }                              // TypeAssertion
	| { ternaryCondition: Node, ternaryConsequent: Node, ternaryAlternate: Node } // ConditionalExpr
	| { spreadArg: Node }                                          // SpreadExpr
	| { newCallee: Node, newArguments: Node[] }                    // NewExpr
	| { tryArg: Node, hasCatch: boolean, catchVal: Node }          // TryExpr
	| { matchDisc: Node, matchCases: Node[] }                      // MatchExpr
	| { casePatterns: Node[], caseGuard: Node, caseBody: Node }    // MatchCase
	| { awaitArg: Node }                                           // AwaitExpr
	| { yieldArg: Node, isDelegate: boolean }                      // YieldExpr
	| { moveArg: Node }                                            // MoveExpr
	| { outArg: Node }                                             // OutExpr
	| { sizeofType: string }                                       // SizeofExpr
	| { convExpr: Node, convType: Type }                           // HiddenStdConv, HiddenSubConv
	| { expr: Node }                                               // HiddenDeref, HiddenAddr
	| { annotationType: string }                                   // TypeAnnotation
	// Pattern variants
	| { patternElements: Node[], hasRestElement: boolean }         // ArrayPattern
	| { patternProps: Node[], hasRestProp: boolean }               // ObjectPattern
	| { propKey: string, propAlias: Node }                         // ObjectPatternProp
	| { destrPattern: Node, destrInit: Node, destrIsConst: boolean } // DestructuringDecl
	// Statement variants
	| { declName: string, declType: string, initializer: Node, declKind: DeclKind, nameLocation: SourceLocation }  // VariableDecl
	| { condition: Node, consequent: Node, alternate: Node }       // IfStmt
	| { whileCondition: Node, whileBody: Node, whileLabel: string } // WhileStmt
	| { forInit: Node, forCondition: Node, forUpdate: Node, forBody: Node } // ForStmt
	| { forOfBinding: string, forOfIsConst: boolean, forOfIterable: Node, forOfBody: Node, forOfPattern: Node, bindingLocation: SourceLocation } // ForOfStmt
	| { forInBinding: string, forInIsConst: boolean, forInObject: Node, forInBody: Node } // ForInStmt
	| { statements: Node[] }                                       // BlockStmt
	| { expr: Node }                                               // ExprStmt
	| { argument: Node | null }                                    // ReturnStmt
	| { breakLabel: string }                                       // BreakStmt
	| { continueLabel: string }                                    // ContinueStmt
	| { fnName: string, params: string[], fnParamTypes: string[], fnBody: Node, fnFlags: string, fnReturnType: string, fnDefaults: Node[], nativeName: string, nameLocation: SourceLocation } // FunctionDecl
	| { doBody: Node, doCondition: Node }                          // DoWhileStmt
	| { switchDisc: Node, switchCases: Node[] }                    // SwitchStmt
	| { caseTests: Node[], caseStmts: Node[], isDefault: boolean } // SwitchCase
	| { unreachableMsg: string }                                   // UnreachableStmt
	| { matchStmtDisc: Node, matchStmtCases: Node[] }              // MatchStmt
	// Declaration variants
	| { importNames: string[], importAliases: string[], importSource: string, nameLocations: SourceLocation[] }  // ImportDecl
	| { exportedDecl: Node }                                       // ExportDecl
	| { aliasName: string, aliasType: string, aliasIsDistinct: boolean, aliasGenericParams: string, discriminantName: string, discriminantType: string, variantKeys: string[], variantTypes: string[], nameLocation: SourceLocation } // TypeAliasDecl
	| { enumName: string, enumMembers: string[], enumValues: number[], nameLocation: SourceLocation, memberLocations: SourceLocation[] } // EnumDecl
	| { interfaceName: string, interfaceFields: string[], interfaceFieldTypes: string[], interfaceExtends: string[], nameLocation: SourceLocation } // InterfaceDecl
	| { interfaceName: string, interfaceFields: string[], interfaceFieldTypes: string[], interfaceExtends: string[], nameLocation: SourceLocation } // StructDecl
	| { className: string, classExtends: string, classBody: Node[], nameLocation: SourceLocation } // ClassDecl
	| { propName: string, propType: string, propIsStatic: boolean, propIsReadonly: boolean, propVisibility: string, propInitializer: Node }  // PropertyDecl
	| { methodName: string, methodParams: string[], methodParamTypes: string[], methodBody: Node, methodIsStatic: boolean, methodFlags: string, methodVisibility: string, methodReturnType: string, methodDefaults: Node[], nativeName: string, nameLocation: SourceLocation } // MethodDecl
	| { ctorParams: string[], ctorParamTypes: string[], ctorBody: Node, ctorDefaults: Node[] } // ConstructorDecl
	// Error handling variants
	| { throwArg: Node }                                           // ThrowStmt
	| { tryBody: Node, catchName: string, catchBody: Node, finallyBody: Node, catchBindingLocation: SourceLocation, hasCatchClause: boolean } // TryCatchStmt
	// Decorator variants
	| { macroName: string, macroArgs: Node[] }                     // MacroInvocation
	| { decorators: Node[], decoratedNode: Node }                  // DecoratedDecl
	| { deferExpr: Node }                                          // DeferStmt
	// Testing variants
	| { testName: string, testBody: Node }                         // TestDecl
	| { assertExpr: Node, assertSource: string, assertMessage: string, assertMessageExpr: Node | null } // AssertStmt
	// Extern / Macro / Quote variants
	| { externKind: ExternKind, externName: string, nativeName: string, externType: string } // ExternDecl
	| { macroDeclName: string, macroDeclParams: string[], macroDeclParamTypes: string[], macroDeclReturnType: string, macroDeclBody: Node } // MacroDecl
	| { quoteBody: Node }                                          // QuoteExpr
	| { comptimeBody: Node }                                       // ComptimeBlock
	// Type expression variants (positioned type AST — standard parity)
	// TypeName uses NodeKind.Identifier with { name: string } — reuses expression kind for type leaf nodes
	| { typExprBase: Node, typExprArgs: Node[] }                   // TypeGeneric
	| { typExprElement: Node, typExprSize: number }                // TypeArray (-1 = unsized)
	// TypeUnion — discriminator metadata surfaced for tagged-union codecs (V3).
	// discFieldName="" + variantKeys=[] + discKind="" mean "no detectable disc"
	// (TS-style DUs auto-detected by codecs walking variants; match-type DUs
	// have these populated by bridge from Type.typeNames + typeExtra).
	// discKind ∈ {"boolean","enum",""} ("" = no disc / TS-style).
	| { typExprMembers: Node[], discFieldName: string, variantKeys: string[], discKind: string }  // TypeUnion
	// TypeIntersection — same Node[] shape, no disc info (intersections aren't DUs).
	| { typExprMembers: Node[] }                                   // TypeIntersection
	| { typExprParams: Node[], typExprReturn: Node, typExprParamNames: string[] } // TypeFunction
	| { typExprFieldNames: string[], typExprFieldTypes: Node[], typExprIndexKey: Node, typExprIndexValue: Node, typExprFieldDecorators: Node[][], typExprTypeName: string }   // TypeObject
	// Program root
	| { programStmts: Node[] }                                     // Program
	// Actor (appended after Program to preserve union discriminant ordering)
	| { actorName: string, actorBody: Node[], nameLocation: SourceLocation } // ActorDecl
	// SERIALIZE A2 — macro multi-decl emission
	| { spliceNodes: Node[] }                                      // SpliceMany
	// JSX (appended at end to preserve union discriminant ordering)
	| { jsxTag: string, jsxAttrs: Node[], jsxChildren: Node[], jsxSelfClosing: boolean } // JSXElement
	| { jsxFragChildren: Node[] }                                  // JSXFragment
	| { jsxText: string }                                          // JSXText
	| { jsxExpr: Node }                                            // JSXExpressionContainer
	| { jsxAttrName: string, jsxAttrValue: Node }                  // JSXAttribute
	| { jsxSpreadArg: Node }                                       // JSXSpreadAttribute

// ===== Flow Graph =====
//
// A Control Flow Graph built by the binder pass between parse and check.
// Each reference expression (Identifier, MemberExpr, etc.) gets a `flowNode`
// pointing into this graph. The checker walks antecedents backward from the
// reference to compute a narrowed type at that program point.
//
// Single FlowNode struct with a FlowFlags bitset tag (NOT a sum type) —
// keeps memory layout simple. Per-variant meaning:
//
// - Start            -> owning function/container (Node=container or null)
// - Assignment       -> the assigned target (VarDecl / BindingElem / Binary LHS)
// - TrueCondition    -> the predicate expression (narrow parent's type assuming true)
// - FalseCondition   -> the predicate expression (narrow parent's type assuming false)
// - SwitchClause     -> synthetic FlowSwitchClauseData (switch stmt + clause range)
// - Call             -> the CallExpr (assertion function / type predicate call)
// - ArrayMutation    -> the mutation call/assignment
// - ReduceLabel      -> synthetic FlowReduceLabelData (try/finally re-routing)
// - BranchLabel      -> fan-in join; Node=null, Antecedents=list of predecessors
// - LoopLabel        -> looping junction; Node=null, Antecedents=list (first = pre-loop)
// - Unreachable      -> singleton after return/throw/break/continue
// - Referenced/Shared -> set by setFlowNodeReferenced; cache metadata, not semantic

export enum FlowFlags {
	Unreachable    = 1,       // 1 << 0
	Start          = 2,       // 1 << 1
	BranchLabel    = 4,       // 1 << 2
	LoopLabel      = 8,       // 1 << 3
	Assignment     = 16,      // 1 << 4
	TrueCondition  = 32,      // 1 << 5
	FalseCondition = 64,      // 1 << 6
	SwitchClause   = 128,     // 1 << 7
	ArrayMutation  = 256,     // 1 << 8
	Call           = 512,     // 1 << 9
	ReduceLabel    = 1024,    // 1 << 10
	Referenced     = 2048,    // 1 << 11
	Shared         = 4096,    // 1 << 12
}

// FlowList — singly-linked list of FlowNode antecedents for join labels.
// Duplicates are dropped at `addAntecedent` time (pointer-equality walk).
export class FlowList {
	flow: FlowNode;
	next: FlowList;
}

// Synthetic node stored in FlowNode.node when Flags contains SwitchClause.
// Represents a half-open range of switch case clauses [clauseStart, clauseEnd).
// Coalesces empty-fallthrough clauses into one range for efficiency.
export class FlowSwitchClauseData {
	switchStatement: Node; // the SwitchStmt AST node
	clauseStart: int32;
	clauseEnd: int32;
}

// Synthetic node stored in FlowNode.node when Flags contains ReduceLabel.
// Used for try/finally re-routing: finally's antecedent set differs depending
// on whether analysis is for normal exit, return exit, or exception exit.
export class FlowReduceLabelData {
	target: FlowNode;        // the LoopLabel/BranchLabel to re-route
	antecedents: FlowList;   // alternate antecedent set for this query context
}

export class FlowNode {
	flags: int32;            // FlowFlags bitset
	node: Node;              // associated AST node (variant-dependent meaning; may be synthetic FlowSwitchClauseData / FlowReduceLabelData holder)
	antecedent: FlowNode;    // single parent (non-Label variants)
	antecedents: FlowList;   // list of parents (BranchLabel / LoopLabel only)
	// Synthetic variant holders (null unless Flags has SwitchClause / ReduceLabel)
	switchClauseData: FlowSwitchClauseData;
	reduceLabelData: FlowReduceLabelData;
}

// ===== Node Interface =====

export class Node {
	kind: NodeKind;
	location: SourceLocation;
	data: NodeData;
	// Compiler-internal: the checker's resolved Type. MACRO BODIES see a
	// different shape here — the VM wire carries a type-AST Node tree
	// (TypeObject/TypeUnion/TypeArray/TypeGeneric/Identifier/literal kinds,
	// from mapTypeToAst), so the engine checker types `node.nodeType` as Node
	// and flat reads (.typExprFieldNames, .discFieldName, ...) resolve per the
	// NodeData unique-field-name rule (checkExprPass engine virtual props).
	nodeType: Type | null;
	resolvedSym: Symbol | null;
	flags: int32;
	comments: Token[]; // Added for comment preservation
	typeExpr: Node | null;    // Positioned type annotation AST (standard parity: PNode type tree alongside string fields)
	typeExprs: (Node | null)[] | null; // Per-param/per-field type annotation ASTs (parallel to string[] type fields). null entry = no annotation for that param.
	paramLocations: SourceLocation[] | null; // Per-param source locations for DEF recording
	typeArg: string; // Explicit generic type arg string (e.g. "Person" from parse<Person>()) — stored on AST, not side-channel
	flowNode: FlowNode; // Flow graph node for narrowing queries. Null until binder runs; null for non-reference nodes.
	// Compiler-side round-trip slot mirrored here for wire parity: the compiler's
	// internal Node keeps nodeType as a checker Type, so valueToNode stores the
	// reconstructed type-AST in nodeTypeAst and nodeToASTLiteral falls back to it
	// for nested re-expansion. Macro bodies should read nodeType (above) — in the
	// VM heap that key always carries the type-AST Node.
	nodeTypeAst: Node;
}

export type Expression = Node;

// ===== Node Data Shape Types =====
// Named aliases for as-casts. Single source of truth for each NodeKind's data shape.

// Literals
// `value` is the double view, kept for the float path and for every consumer that
// only needs magnitude. `intVal` is authoritative when !isFloat: a double cannot
// round-trip an integer past 2^53, so the exact value would otherwise be lost in
// the parser, before any backend sees it.
export type NumberLiteralData = { value: number, isFloat: boolean, intVal: int64, outOfRangeText: string, isBitPattern: boolean };
export type StringLiteralData = { value: string };
export type BooleanLiteralData = { boolValue: boolean };
export type RegexLiteralData = { regexPattern: string };
export type BigIntLiteralData = { bigintValue: string };

// Expressions
export type IdentifierData = { name: string };
export type BinaryExprData = { operator: string, left: Node, right: Node };
export type UnaryExprData = { unaryOp: string, operand: Node };
export type UpdateExprData = { updateOp: string, updateArg: Node, isPrefix: boolean };
export type CallExprData = { callee: Node, arguments: Node[], isDirectCall: boolean, resolvedOverloadIdx: number };
export type MemberExprData = { object: Node, property: string, isOptional: boolean };
export type ArrayAccessData = { array: Node, index: Node };
export type ObjectLiteralData = { properties: Node[], keys: string[], keyLocations: SourceLocation[] };
export type ArrayLiteralData = { elements: Node[] };
export type ArrowFunctionData = { arrowParams: string[], arrowParamTypes: string[], arrowBody: Node, arrowFlags: string, arrowReturnType: string, arrowDefaults: (Node | null)[] };
export type FunctionExprData = { funcExprParams: string[], funcExprParamTypes: string[], funcExprBody: Node, funcExprFlags: string, funcExprReturnType: string };
export type TypeAssertionData = { asExpr: Node, asType: string };
export type ConditionalExprData = { ternaryCondition: Node, ternaryConsequent: Node, ternaryAlternate: Node };
export type SpreadExprData = { spreadArg: Node };
export type NewExprData = { newCallee: Node, newArguments: Node[] };
export type TryExprData = { tryArg: Node, hasCatch: boolean, catchVal: Node };
export type MatchExprData = { matchDisc: Node, matchCases: Node[] };
export type MatchCaseData = { casePatterns: Node[], caseGuard: Node, caseBody: Node };
export type AwaitExprData = { awaitArg: Node };
export type YieldExprData = { yieldArg: Node, isDelegate: boolean };
export type MoveExprData = { moveArg: Node };
export type OutExprData = { outArg: Node };
export type SizeofExprData = { sizeofType: string };
export type HiddenStdConvData = { convExpr: Node, convType: Type };
export type TypeAnnotationData = { annotationType: string };

// Patterns
export type ArrayPatternData = { patternElements: Node[], hasRestElement: boolean };
export type ObjectPatternData = { patternProps: Node[], hasRestProp: boolean };
export type ObjectPatternPropData = { propKey: string, propAlias: Node };
export type DestructuringDeclData = { destrPattern: Node, destrInit: Node, destrIsConst: boolean };

// Statements
export type VariableDeclData = { declName: string, declType: string, initializer: Node, declKind: DeclKind, nameLocation: SourceLocation };
export type IfStmtData = { condition: Node, consequent: Node, alternate: Node };
export type WhileStmtData = { whileCondition: Node, whileBody: Node, whileLabel: string };
export type ForStmtData = { forInit: Node, forCondition: Node, forUpdate: Node, forBody: Node };
export type ForOfStmtData = { forOfBinding: string, forOfIsConst: boolean, forOfIterable: Node, forOfBody: Node, forOfPattern: Node, bindingLocation: SourceLocation };
export type ForInStmtData = { forInBinding: string, forInIsConst: boolean, forInObject: Node, forInBody: Node };
export type BlockStmtData = { statements: Node[] };
export type ExprStmtData = { expr: Node };
export type ReturnStmtData = { argument: Node | null };
export type BreakStmtData = { breakLabel: string };
export type ContinueStmtData = { continueLabel: string };
export type FunctionDeclData = { fnName: string, params: string[], fnParamTypes: string[], fnBody: Node, fnFlags: string, fnReturnType: string, fnDefaults: Node[], nativeName: string, nameLocation: SourceLocation };
export type DoWhileStmtData = { doBody: Node, doCondition: Node };
export type SwitchStmtData = { switchDisc: Node, switchCases: Node[] };
export type SwitchCaseData = { caseTests: Node[], caseStmts: Node[], isDefault: boolean };
export type UnreachableStmtData = { unreachableMsg: string };
export type MatchStmtData = { matchStmtDisc: Node, matchStmtCases: Node[] };

// Declarations
export type ImportDeclData = { importNames: string[], importAliases: string[], importSource: string, nameLocations: SourceLocation[] };
export type ExportDeclData = { exportedDecl: Node };
export type TypeAliasDeclData = { aliasName: string, aliasType: string, aliasIsDistinct: boolean, aliasGenericParams: string, discriminantName: string, discriminantType: string, variantKeys: string[], variantTypes: string[], nameLocation: SourceLocation };
export type EnumDeclData = { enumName: string, enumMembers: string[], enumValues: number[], nameLocation: SourceLocation, memberLocations: SourceLocation[] };
export type InterfaceDeclData = { interfaceName: string, interfaceFields: string[], interfaceFieldTypes: string[], interfaceExtends: string[], nameLocation: SourceLocation };
export type StructDeclData = { interfaceName: string, interfaceFields: string[], interfaceFieldTypes: string[], interfaceExtends: string[], nameLocation: SourceLocation };
export type ClassDeclData = { className: string, classExtends: string, classBody: Node[], nameLocation: SourceLocation };
export type ActorDeclData = { actorName: string, actorBody: Node[], nameLocation: SourceLocation };
export type PropertyDeclData = { propName: string, propType: string, propIsStatic: boolean, propIsReadonly: boolean, propVisibility: string, propInitializer: Node }; // propVisibility: "" | "public" | "private" | "protected"
export type MethodDeclData = { methodName: string, methodParams: string[], methodParamTypes: string[], methodBody: Node, methodIsStatic: boolean, methodFlags: string, methodVisibility: string, methodReturnType: string, methodDefaults: Node[], nativeName: string, nameLocation: SourceLocation };
export type ConstructorDeclData = { ctorParams: string[], ctorParamTypes: string[], ctorBody: Node, ctorDefaults: Node[] };
export type ExternDeclData = { externKind: ExternKind, externName: string, nativeName: string, externType: string };
export type MacroDeclData = { macroDeclName: string, macroDeclParams: string[], macroDeclParamTypes: string[], macroDeclReturnType: string, macroDeclBody: Node };
export type DecoratedDeclData = { decorators: Node[], decoratedNode: Node };
export type ProgramData = { programStmts: Node[] };
export type SpliceManyData = { spliceNodes: Node[] };
export type DeferStmtData = { deferExpr: Node };
export type ThrowStmtData = { throwArg: Node };
export type TryCatchStmtData = { tryBody: Node, catchName: string, catchBody: Node, finallyBody: Node, catchBindingLocation: SourceLocation, hasCatchClause: boolean };
export type MacroInvocationData = { macroName: string, macroArgs: Node[] };
export type HiddenDerefData = { expr: Node };
export type TestDeclData = { testName: string, testBody: Node };
export type AssertStmtData = { assertExpr: Node, assertSource: string, assertMessage: string, assertMessageExpr: Node | null };
export type QuoteExprData = { quoteBody: Node };
export type ComptimeBlockData = { comptimeBody: Node };

// Type expression data types (positioned type AST — standard parity)
// Leaf type names use IdentifierData (NodeKind.Identifier) — reuses expression kind for type leaf nodes
export type TypeGenericData = { typExprBase: Node, typExprArgs: Node[] };
export type TypeArrayData = { typExprElement: Node, typExprSize: number };
// TypeUnionData — variants + discriminator metadata (V3 tagged-union support).
// discFieldName/variantKeys/discKind populated only for match-type DUs (where
// disc info pre-stored in Type.typeNames + typeExtra). TS-style DUs leave them
// empty — codecs detect by walking variants (each variant struct has disc field).
export type TypeUnionData = {
	typExprMembers: Node[],
	discFieldName: string,
	variantKeys: string[],
	discKind: string,
};
// TypeIntersectionData — same Node[] shape, no disc info (intersections aren't DUs).
export type TypeIntersectionData = { typExprMembers: Node[] };
export type TypeFunctionData = { typExprParams: Node[], typExprReturn: Node, typExprParamNames: string[] };
// typExprIndexKey / typExprIndexValue are non-null ONLY when the type is an index signature
// like { [key: K]: V }. After checker normalization this becomes Map<K, V>. Mixed (named fields
// + index signature in the same type) is rejected by the parser. See docs and plan for details.
export type TypeObjectData = { typExprFieldNames: string[], typExprFieldTypes: Node[], typExprIndexKey: Node, typExprIndexValue: Node, typExprFieldDecorators: Node[][], typExprTypeName: string };

// JSX (compile-time only — erased by consuming macro before codegen)
export type JSXElementData = { jsxTag: string, jsxAttrs: Node[], jsxChildren: Node[], jsxSelfClosing: boolean };
export type JSXFragmentData = { jsxFragChildren: Node[] };
export type JSXTextData = { jsxText: string };
export type JSXExpressionContainerData = { jsxExpr: Node };
export type JSXAttributeData = { jsxAttrName: string, jsxAttrValue: Node };
export type JSXSpreadAttributeData = { jsxSpreadArg: Node };

// ===== Constructors =====

export function createNode(kind: NodeKind, data: NodeData, token: Token): Node {
	const n = new Node();
	n.kind = kind;
	n.data = data;
	n.location = makeLoc(token.line, token.column);
	n.nodeType = null;
	n.resolvedSym = null;
	n.flags = 0;
	n.comments = [];
	n.typeExpr = null;
	n.typeExprs = null;
	n.paramLocations = null;
	n.typeArg = "";
	n.flowNode = null as unknown as FlowNode;
	n.nodeTypeAst = null as unknown as Node;
	return n;
}

// createNodeAt — overloaded constructor for AST nodes. Per-kind signatures
// pair each NodeKind with its matching *Data shape so macro authors see the
// correct fields in IDE completion / signature help when calling
// `createNodeAt(NodeKind.BinaryExpr, { ... }, loc)`. The wide implementation
// at the bottom accepts any NodeKind + NodeData union so existing compiler
// callers that pass runtime `kind`/`data` continue to work.
//
// Phase 5 enabled this pattern via contextual arg typing against the wide
// impl in resolveOverloadCall — object literals contextually narrow via the
// wide NodeData union, then scoring picks the specific overload.

// Literals
export function createNodeAt(kind: NodeKind.NumberLiteral, data: NumberLiteralData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.StringLiteral, data: StringLiteralData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.BooleanLiteral, data: BooleanLiteralData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.BigIntLiteral, data: BigIntLiteralData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.RegexLiteral, data: RegexLiteralData, loc: SourceLocation): Node;
// Identifier
export function createNodeAt(kind: NodeKind.Identifier, data: IdentifierData, loc: SourceLocation): Node;
// Expressions
export function createNodeAt(kind: NodeKind.BinaryExpr, data: BinaryExprData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.UnaryExpr, data: UnaryExprData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.UpdateExpr, data: UpdateExprData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.CallExpr, data: CallExprData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.MemberExpr, data: MemberExprData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.ArrayAccess, data: ArrayAccessData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.ObjectLiteral, data: ObjectLiteralData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.ArrayLiteral, data: ArrayLiteralData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.ArrowFunction, data: ArrowFunctionData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.FunctionExpr, data: FunctionExprData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.TypeAssertion, data: TypeAssertionData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.ConditionalExpr, data: ConditionalExprData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.SpreadExpr, data: SpreadExprData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.NewExpr, data: NewExprData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.TryExpr, data: TryExprData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.MatchExpr, data: MatchExprData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.MatchCase, data: MatchCaseData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.AwaitExpr, data: AwaitExprData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.YieldExpr, data: YieldExprData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.MoveExpr, data: MoveExprData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.OutExpr, data: OutExprData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.HiddenDeref, data: HiddenDerefData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.HiddenStdConv, data: HiddenStdConvData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.TypeAnnotation, data: TypeAnnotationData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.SizeofExpr, data: SizeofExprData, loc: SourceLocation): Node;
// Patterns
export function createNodeAt(kind: NodeKind.ArrayPattern, data: ArrayPatternData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.ObjectPattern, data: ObjectPatternData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.ObjectPatternProp, data: ObjectPatternPropData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.DestructuringDecl, data: DestructuringDeclData, loc: SourceLocation): Node;
// Statements
export function createNodeAt(kind: NodeKind.VariableDecl, data: VariableDeclData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.IfStmt, data: IfStmtData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.WhileStmt, data: WhileStmtData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.ForStmt, data: ForStmtData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.ForOfStmt, data: ForOfStmtData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.ForInStmt, data: ForInStmtData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.BlockStmt, data: BlockStmtData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.ExprStmt, data: ExprStmtData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.ReturnStmt, data: ReturnStmtData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.BreakStmt, data: BreakStmtData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.ContinueStmt, data: ContinueStmtData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.FunctionDecl, data: FunctionDeclData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.DoWhileStmt, data: DoWhileStmtData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.SwitchStmt, data: SwitchStmtData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.SwitchCase, data: SwitchCaseData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.UnreachableStmt, data: UnreachableStmtData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.MatchStmt, data: MatchStmtData, loc: SourceLocation): Node;
// Declarations
export function createNodeAt(kind: NodeKind.ImportDecl, data: ImportDeclData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.ExportDecl, data: ExportDeclData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.TypeAliasDecl, data: TypeAliasDeclData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.EnumDecl, data: EnumDeclData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.InterfaceDecl, data: InterfaceDeclData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.StructDecl, data: StructDeclData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.ClassDecl, data: ClassDeclData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.ActorDecl, data: ActorDeclData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.PropertyDecl, data: PropertyDeclData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.MethodDecl, data: MethodDeclData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.ConstructorDecl, data: ConstructorDeclData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.ExternDecl, data: ExternDeclData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.MacroDecl, data: MacroDeclData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.DecoratedDecl, data: DecoratedDeclData, loc: SourceLocation): Node;
// Error handling
export function createNodeAt(kind: NodeKind.ThrowStmt, data: ThrowStmtData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.TryCatchStmt, data: TryCatchStmtData, loc: SourceLocation): Node;
// Decorators & macros
export function createNodeAt(kind: NodeKind.MacroInvocation, data: MacroInvocationData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.DeferStmt, data: DeferStmtData, loc: SourceLocation): Node;
// Testing
export function createNodeAt(kind: NodeKind.TestDecl, data: TestDeclData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.AssertStmt, data: AssertStmtData, loc: SourceLocation): Node;
// Quote / Comptime
export function createNodeAt(kind: NodeKind.QuoteExpr, data: QuoteExprData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.ComptimeBlock, data: ComptimeBlockData, loc: SourceLocation): Node;
// Type expression nodes
export function createNodeAt(kind: NodeKind.TypeGeneric, data: TypeGenericData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.TypeArray, data: TypeArrayData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.TypeUnion, data: TypeUnionData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.TypeIntersection, data: TypeIntersectionData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.TypeFunction, data: TypeFunctionData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.TypeObject, data: TypeObjectData, loc: SourceLocation): Node;
// Program
export function createNodeAt(kind: NodeKind.Program, data: ProgramData, loc: SourceLocation): Node;
// SpliceMany — A2 macro multi-decl emission
export function createNodeAt(kind: NodeKind.SpliceMany, data: SpliceManyData, loc: SourceLocation): Node;
// JSX (compile-time only — erased by consuming macro before codegen)
export function createNodeAt(kind: NodeKind.JSXElement, data: JSXElementData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.JSXFragment, data: JSXFragmentData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.JSXText, data: JSXTextData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.JSXExpressionContainer, data: JSXExpressionContainerData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.JSXAttribute, data: JSXAttributeData, loc: SourceLocation): Node;
export function createNodeAt(kind: NodeKind.JSXSpreadAttribute, data: JSXSpreadAttributeData, loc: SourceLocation): Node;

// Implementation — widest signature, accepts any NodeKind and the NodeData union.
// This is the body; all overload signatures above delegate here via the checker's
// overload resolution. It also serves as the fallback for callers that pass a
// runtime (non-literal) NodeKind or a NodeData value that isn't known to narrow.
export function createNodeAt(kind: NodeKind, data: NodeData, loc: SourceLocation): Node {
	const n = new Node();
	n.kind = kind;
	n.data = data;
	n.location = loc;
	n.nodeType = null;
	n.resolvedSym = null;
	n.flags = 0;
	n.comments = [];
	n.typeExpr = null;
	n.typeExprs = null;
	n.paramLocations = null;
	n.typeArg = "";
	n.flowNode = null as unknown as FlowNode;
	n.nodeTypeAst = null as unknown as Node;
	return n;
}

// ===== Node Cache (DRC-safe: Node in struct fields ONLY here) =====

interface NodeCacheEntry {
	key: number;
	node: Node;
}

const nodeCache: NodeCacheEntry[] = [];

export function nodeCacheGet(key: number): Node {
	let i = 0;
	while (i < nodeCache.length) {
		if (nodeCache[i].key === key) return nodeCache[i].node;
		i = i + 1;
	}
	return null as unknown as Node;
}

export function nodeCacheStore(key: number, node: Node): void {
	let i = 0;
	while (i < nodeCache.length) {
		if (nodeCache[i].key === key) {
			nodeCache[i].node = node;
			return;
		}
		i = i + 1;
	}
	nodeCache.push({ key, node });
}

export function isEmptyBlock(node: Node): boolean {
	if (node === null) return true;
	if (node.kind !== NodeKind.BlockStmt) return false;
	const d = node.data as BlockStmtData;
	return d.statements.length === 0;
}

// Flatten a left-associative BinaryExpr(+) chain into its leaf nodes.
// Used by @emit template interpolation (checker) and string concat flattening (transform).
// Iterative stack approach (C-safe: avoids mutable array params).
export function collectConcatParts(node: Node): Node[] {
	const result: Node[] = [];
	const stack: Node[] = [node];
	while (stack.length > 0) {
		const cur = stack.pop();
		if (cur.kind === NodeKind.BinaryExpr) {
			const d = cur.data as BinaryExprData;
			if (d.operator === "+") {
				stack.push(d.right);
				stack.push(d.left);
				continue;
			}
		}
		result.push(cur);
	}
	return result;
}
