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
	// AwaitableScopeBound in typeFlags.
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
	// Appended at the tail on purpose: inserting mid-enum shifts every later
	// ordinal and desyncs the previous-generation builder's macro bridge —
	// builds hang deterministically in expand. Append-only, like every member
	// after Error.
	BigInt,
	Set,
	Module,
	IndexedAccess,
	KeyOf,
	NumberLiteral,
	NonPrimitive,
	Mapped,
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
	IsStruct,
	IsMaybe,
	HasAsgn,
	AwaitableAffine,      // PARALOCK affine (spawn-origin Promise)
	AwaitableScopeBound,  // PARALOCK R3/E4 (cannot escape creating scope)
	HasInheritedFields,   // class has flattened parent fields (suppresses DRC parent-call)
	IsAtomic,             // Arc<T> atomic-rc marker on a Ref
	DuVariant,            // INLINE (nameless) union-variant payload struct; lifecycle owned by the DU machinery, analyzer defers (classify → no RC)
	OpenClass,            // class is extended (non-final), stamped on the PARENT struct in resolveClass with each subclass noted on the parent's symbol (`subclasses`): a CBase-typed field may point at a subclass that closes a back-edge, so canFormAcycle walks them, and without notes the class is cyclic (the tfFinal rule)
	BrandWiden,           // TS branded primitive (`Prim & { __brand }`): Distinct that widens implicitly to its base; erased to base after check (brandErase)
	IsLocked,             // Locked<T> marker, always set together with IsAtomic: the handle IS an atomic Ref whose pointee is the generated `{ lockNext, lockServing, lockHolder, value }` cell (PARALOCK I22)
	IsReadonly,           // read-only view of a Ref or Array: no write reaches through it and it never converts back to the mutable type (PARALOCK E24)
	PtrIntroduced,        // Ptr<T> introduced by pointer-param introduction, not user-declared
	HasGenericParam,
	BorrowDot,
	Spelled,              // the compiler spelled this name from an owner and arguments: it is the identity and no declaring symbol exists
	OutParam,             // a Var parameter type written `out`: the callee fills it, so an unassigned variable may be passed
	ValueUnion,           // a discriminated union declared `struct X = match`: a value, copied where a `type X = match` union is shared
	ArityAdapter,         // env of a closure that drops the slot's trailing arguments: identity compares its adaptee
	CompleteStruct,       // extern struct whose declared fields are all of C's, from a header translation: its layout is folded and asserted against C
	CUnion,               // CompleteStruct translated from a C union: its members overlay at offset 0
	IsSendable,           // Sendable<F>: a function value admitted only from a source whose captures may cross a thread
	IsOwned,              // Owned<T> on a class Ref: an owning edge; a cycle made only of owning edges does not keep its class under the collector
	IsUnowned,            // Unowned<T> on a class Ref: a stored edge counted on the target's second count; it never keeps the target alive and its target cannot die while it exists
}

// ===== Attached Lifecycle Ops =====
export enum AttachedOp {
	AttachedWasMoved,
	AttachedDestructor,
	AttachedAsgn,
	AttachedDup,
	AttachedSink,
	AttachedTrace,
	AttachedEq,
	AttachedLt,
	AttachedLe,
	AttachedToString,
	AttachedCustody,
	AttachedFinalize,
	AttachedRelease,
	AttachedReach,
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
//   typeFlags      — BitSet<TypeFlag> (HasAsgn, IsStruct, AwaitableAffine, ...) — propagated
//                    bottom-up by propagateToOwner when building parent types.
//   typeValue      — kind-specific integer: SizedArray → element count; enum member
//                    (Number child of an Enum) → ordinal value; Function → minArity + 1.
//   attachedOps    — lifecycle op Symbols (index = AttachedOp enum: Destroy/Copy/Sink/...;
//                    null = absent). Populated by destructorLifting; see setAttachedOp /
//                    getAttachedOp in src/checker/types.ms.
//   sym            — back-pointer to the declaring Symbol (Class/Interface/Enum decls).
//   typeInst       — a union built as a generic instance's body: that instance, which names it.
export class Type {
	kind: TypeKind;
	typeName: string;
	typeNames: string[];
	typeChildren: Type[];
	typeReturn: Type | null;
	typeExtra: Type | null;
	typeParamDefault: Type | null; // GenericParam: checked default, independent of its constraint.
	typeFlags: BitSet<TypeFlag>;
	typeValue: int32;
	callConv: CallingConvention;
	attachedOps: (Unowned<Symbol> | null)[];
	sym: Unowned<Symbol> | null;
	typeInst: Type | null;
	readonlyView: Type | null;
	mutableView: Type | null;
	ownedType: Type | null;
	plainType: Type | null;
	optionalFields: string[] | null; // Struct: the fields written `name?`, own and inherited
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
	Temp,
}

// ===== Symbol State (Lifecycle) =====

export enum SymbolState {
	Hollow,    // Registered only (Pass 1)
	Shaping,   // Currently resolving signature (Pass 2 re-entrancy guard)
	Shaped,    // Signature (params/return/fields) resolved
	Checking,  // Currently checking body (Pass 3)
	Checked,   // Fully validated
}

// Bitfield for Symbol.symFlags — tracks declaration properties.
export enum SymbolFlag {
	Used,           // symbol is referenced somewhere
	Exported,       // symbol is exported
	Mutable,        // let/var/mutable
	Forward,        // forward declaration (body not yet seen)
	Global,        // module-level variable
	ImportC,       // extern declaration (extern ... from)
	CompileTime,  // @comptime
	GcSafe,       // no GC-unsafe operations
	WasForwarded, // had forward decl, now has body
	Static,      // static class member or static linkage
	Sink,        // parameter takes ownership
	Lent,        // parameter is a borrow (no RC)
	NoReturn,    // function never returns (exit, abort, infinite loop)
	Async,      // async function (return type is Promise<T>)
	ParamMutated,  // parameter is mutated inside function body (blocks const-ptr promotion)
	HasConstructor, // class has a ConstructorDecl → codegen calls ClassName_new()
	NativeMethod, // method from extern class — don't set ExtCall, keep as native member call
	GeneratedOp, // generated lifecycle hook (=destroy/=copy/=sink/=wasMoved) — skip DRC injection (reference parity: sfGeneratedOp)
	Nonisolated, // @nonisolated — actor field/method readable from outside (Swift parity)
	Consumed, // PARALOCK Phase 1: affine-Promise binding (spawn-origin) has been awaited (affine consumption)
	OverloadSig, // Tier 1: body-less overload signature — typecheck-only, codegen skips emission
	OverloadValidated, // Tier 1: overload set already validated (return-type compatibility check)
	OverloadRejected, // that validation failed: the error is already on the signature
	SinkTemp, // DRC sink-arg temp synthesized by passCopyToSink — always single-use by construction, always last-read
	ComptimeNodeAlias, // `const x = <jsx>` — x binds a compile-time Node, folded into the consuming macro; emits no runtime decl
	StaticLocal, // `static` decl inside a body: carries Global (module storage) but is named per-site, since a body can hold several and a module may hold several bodies
	ActorProxy, // symbol is an actor-method proxy (actorLower): an UNPARKED call to it is a
	                       // SEND-class handoff — plain-ref args transfer ownership into the message
	AwaitHandle, // awaitLower's `$fut` hoist temp: the initializer call is PARKED on
	                         // (msWaitForReady below) — its args pass as borrows; the scope outlives the flight
	Cursor, // binding does not own its referent — DRC skips incref and destroy
	Throws, // @throws — an extern routine that raises through the runtime error flag rather than returning
	Converter,
	DestroyOp,
	WasMovedOp,
	BeforeReload,
	AfterReload,
	StateMachine,
	ForVar, // for-of loop binding (reference: skForVar) — rebinding legal, value interior read-only
	Borrow,
	NeverRaises,
	HcrCell, // pointer to a lifted module variable's registry storage; the analyzer destroys `(*ptr).value` at program end
	ClassInit,
	Inline,
	InheritsConstructor,
	NoInline,
	HoistedCall, // a `__call_N_` temp the conditional lowering binds to a raising call: the value is the call and nothing else
	InitFlag, // a module binding's initialized flag (moduleTdz); HCR keeps it in step with the binding's state cell
	Anon, // minted by a transform: its name is generated and positional, never one the author wrote
	UnavailableOp, // a lifted hook no site may call: the analyzer refuses each copy that needs it (reference: sfError on a hook)
	Acyclic, // a class's trace routine whose cells cannot form a cycle: its TypeInfo says isCyclic false
	CompilerProc, // a routine a synthesized call names: a @compilerFunc declaration or a generated runtime proc (reference: sfCompilerProc)
	TypeBoundOp, // a routine attached to its canonical type as one of the type's ops: it takes public linkage
	ClosureEnv, // the struct lambda lifting builds to hold a frame's captured variables
	IteratorHelper, // @iteratorHelper std generator: a close before its first next closes its first parameter, the source iterator
	ImmutableEnv, // a ClosureEnv whose every captured variable is a const: no field is written after the env is built
	ImmutableModuleConst, // a module const the checker proved never written, on the source tree: a borrow of it takes no count on any thread
	JsCell, // JS: a `ref` borrow takes this binding, so every module reads and writes it through a one-element cell
	Wasm, // @wasm: an exported function the js build places in its wasm half
	OwnedCycle, // the trace of a class that stays under the collector only because this build checks owned cycles: a dead set holding one stops the program
	JsHost, // @jsHost class, and each of its members: on the JS backend the host's class of the same name is the value and its members
}

// The compiler-intercepted operation a symbol stands for: `@builtin("Name")` in the standard
// library names a member, and None marks an ordinary symbol.
export enum BuiltinKind {
	None,
	Array,
	AsBytes,
	BoxArc,
	BoxLocked,
	BoxRefArray,
	CollectCycles,
	compilerFunc,
	delegate,
	DynamicImport,
	Echo,
	Exit,
	FfiHandle,
	FfiVecBox,
	Float64Bits,
	Float64FromBits,
	FutureCreateInline,
	FutureThenBoxed,
	HiXorLo,
	HoldsArray,
	IndexableMap,
	Infinity,
	IsArray,
	IsObject,
	IsPlainData,
	IsPlainObject,
	Iterator,
	JsonValueData,
	LoadLE32,
	LoadLE64,
	LockedLoad,
	LockedStore,
	MapFatal,
	MapFromPairs,
	MetaBindSym,
	MetaCreateNode,
	MetaCreateNodeAt,
	MetaDeclKind,
	MetaError,
	MetaExternKind,
	MetaGetTypeArg,
	MetaGetTypeImpl,
	MetaNode,
	MetaNodeKind,
	MetaSplice,
	MetaWarning,
	ModuleImport,
	Name,
	NaN,
	NeedsCopy,
	nonisolated,
	NumberArrayFrom,
	OrcDisownValue,
	Promise,
	PromiseAll,
	PromiseAllFor,
	PromiseAllSettled,
	PromiseAny,
	PromiseAnyFor,
	PromiseCatch,
	PromiseFail,
	PromiseFinally,
	PromisePending,
	PromiseRace,
	PromiseRaceFor,
	PromiseReject,
	PromiseResolve,
	PromiseSettle,
	PromiseSpawn,
	PromiseThen,
	Proxy,
	PtrBits,
	Result,
	ResultErr,
	ResultOk,
	SetDifference,
	SetExcl,
	SetHas,
	SetHash,
	SetIncl,
	SetIntersection,
	SetIsDisjointFrom,
	SetIsEmpty,
	SetIsSubsetOf,
	SetIsSupersetOf,
	SetSize,
	SetSymmetricDifference,
	SetUnion,
	SinkBoxStruct,
	SleepAsync,
	SleepCancel,
	SleepTask,
	SpawnInto,
	StdSet,
	StringAppendArr,
	StringArrayFromArr,
	StringConcatArr,
	Swap,
	throws,
	ToString,
	ToStringMethod,
	TypedArray,
	UnboxStruct,
	UnionDebug,
	UnionEq,
	UnionText,
	WaitForStruct,
}

// ===== Symbol =====

export class Symbol {
	name: string;
	nameId: int32;
	symbolKind: SymbolKind;
	symbolType: Type;
	state: SymbolState;
	location: SourceLocation;
	declNode: Unowned<Node>;
	overloads: Owned<Symbol>[];
	nativeName: string;
	exportName: string;
	builtinKind: BuiltinKind;
	symFlags: BitSet<SymbolFlag>;
	defaultParams: Unowned<Node>[];
	modulePath: string;
	headerPath: string;    // @include header for this extern symbol
	jsModulePath: string;  // @import JS module for this extern symbol
	overloadIdx: int32;    // Index within overload set (0=primary, 1+=overload)
	disamb: int32;         // Per-(module, name) ordinal minted at declaration; the C name's _u suffix. Distinct from overloadIdx: a name that never joins an overload set still needs one, and it must travel with the symbol across module boundaries rather than be recomputed from position.
	mutatedParams: int32;  // Bitfield: bit i = param i is mutated in body (gates const-ptr promotion)
	sunkParams: int32;  // Bitfield of a constructor: bit i = the body keeps param i in an owning place, so a caller hands that argument over; bit 0 = the bits are final
	staticFields: Owned<Symbol>[];  // Static properties (only for class symbols)
	fieldDecoratorNames: string[];
	fieldDecorators: Unowned<Node>[][];
	metaKeys: string[];
	metaValues: Unowned<Node>[];
	nonisolatedFields: string[];
	duVariantSlot: int32;  // Narrowed DU field access: 0 = none, N = union variant N-1 (checker stamps on the property sym; C codegen routes .v<N-1>)
	itemModule: int32;     // Identity within one compilation: the owning module's index and the ordinal of this symbol in it
	item: int32;
	instantiatedFrom: Unowned<Symbol> | null;
	instanceArgs: Type[] | null;
	instanceParams: Type[] | null;
	ctorRoutine: Owned<Symbol> | null;
	ctorOwner: Unowned<Symbol> | null;
	borrowedFrom: Unowned<Symbol> | null;
	staticOwner: Unowned<Symbol> | null;
	typeParamOwner: Unowned<Symbol> | null;
	typeParams: Type[];
	subclasses: Type[] | null; // Class: the structs of the classes that extend it, noted when each subclass resolves; every copy of the class's type shares this symbol
}

// ===== Node Flags (Standard parity: TNodeFlags) =====
// Bitfield on Node.flags — tracks processing state and optimization hints.
export enum NodeFlag {
	Sem,            // semantic pass done (skip re-checking)
	Transf,         // transform pass done (skip re-transforming)
	LL,             // lambda lifting done
	LastRead,       // DRC: this is the last read of a variable
	FirstWrite,    // DRC: this is the first write to a variable
	PreventCG,     // skip in codegen
	FromTemplate,  // generated by template/macro expansion
	Closure,      // ObjectLiteral is a closure pair {fn, env}
	ExtCall,      // checker: this CallExpr is an extension method call (UFCS)
	ExtStatic,   // checker: this extension call or member read is static (no receiver)
	ExportDefault, // parser: export default declaration
	WasAsync,      // transform: function was async before asyncDesugar rewrote to generator
	ExternC,       // parser: extern interface — type defined in C header, skip codegen emission
	BoundSym,     // macro bindSym: resolvedSym pre-bound in the macro's module — checker must not re-lookup
	Converter,    // parser: MacroDecl is a converter — compiler-invoked at settled type boundaries
	StaticStorage, // parser: VariableDecl declared `static` inside a body — storage at module scope (reference: global storage flag)
	ProtocolCall,
	Parenthesized, // parser: the expression was written inside grouping parentheses
	WhenPicked,    // parser: statement spliced in from the selected branch of a `when` chain
	ExplicitDeref, // parser: HiddenDeref written as `x[]` — the checker validates the pointer, fmt prints it back
	CommaWritten,  // parser: a comma was written after this match case
	ObjCheck,      // checker: this TypeAssertion is an object down-conversion checked at run time
	ConvCheck,     // checker: this conversion narrows to a union member or into a string-literal union, tested at run time
	NoFieldCheck,
	GlobalDestroys,
	UserOp,        // checker: this operator calls a declared routine, not the built-in
	ObjectSlot,    // checker: this union projection reads whichever slot holds an object, the conversion above it checks the class
	CanRaise,      // raises inference: this statement's value holds a call that can raise
	CannotRaise,   // raises inference: no call in this statement's value can raise
	RaisingCall,   // raises inference: this call or `new` can raise
	NonRaisingCall, // raises inference: this call or `new` cannot raise
	WhenDeferred,  // parser: a `when` chain kept as nested IfStmt because a condition asks a type trait; the checker picks the branch per instance
	Folded,        // checker: literal a @comptime call folded to; a macro that hands it back gets it re-checked as the call's type
	Accessor,      // parser: this routine is a `get`/`set` accessor — `o.x` reads call it, `o.x = v` writes call it
	OptionalChainEnd, // parser: last link of a run that starts at `?.` — the null test covers every link from the `?.` to here
	AutoAccessor,  // parser: this class field was written `accessor x` — a hidden storage field plus a getter and a setter replace it before the class is filled
	KeyOps,        // JS transform: a std collection construction carries [initializer, key hash, key ==] as its arguments
	AssertedNull,  // checker: `null as T` folded to a typed null literal; its value is the asserted T, so an assignment narrows to T
	UserOpStores,  // checker: this compound assignment calls its base operator's declared routine and stores the result in its target
	NoOverflowCheck, // transform: the step of a counter the compiler keeps below a length, which cannot overflow
	ValueUnion,    // parser: this TypeAliasDecl is a discriminated union written `struct X = match`
	QuoteSplice,   // parser: this call is a quote's `${ }` interpolation, a splice by syntax whatever `splice` names in scope
	TypeOnlyImport, // checker: every binding of this ImportDecl is used only as a type, so it does not evaluate its module
	TypeModifier,   // parser: the declaration is spelled `import type` / `export type`; `importTypeNames` holds the specifiers spelled `type A`
	Optional,      // parser: this class field was written `name?`
	ContinuesList, // parser: this declarator follows a comma in the declaration list of the statement before it
	NoDispatch,    // transform: this identifier, or the member of a `super.m` call, calls the routine it names, never the dispatcher of its overrides (reference: procCall)
	Isolated,      // checker: this spawn's thunk captures no reference from its parent, so no scope exit joins it
	OptionalLink,  // parser: this call or index was written `?.(` or `?.[`, so its callee or array starts an optional chain
	Abstract,      // parser: this class or member was written `abstract` — fmt prints it back
	ActorSelfCall, // checker: a call through `this` in the actor's own method runs the method body on this turn, not as a message
	TemplateStep,  // parser: this `+` is one step of a template literal; its right operand converts to text with the string hint
	DefaultAwaitsInstance, // checker: a filled default whose formal is still generic; the instantiation fits it to the instance's type
	ParamProperty, // checker: this class field was declared by a constructor parameter written with `public`, `private`, `protected` or `readonly`
	SendableClosure, // checker: this closure is converted to Sendable<F>, so lambda lifting gives it an env of its own that holds copies of its captures
	ConstData,     // transform: every element of this array literal is deep-constant data, so codegen copies one static initializer
	DecoratorRefused, // checker: a decorator on this declaration was refused, so a check that would only follow from it skips the declaration
	LendsPastCall, // checker: this call of an async routine returns while a spawn it started still borrows from the caller, so a scope exit joins its promise
	InBounds,      // transform: the for-of lowering's own element read, whose index the loop keeps below the length its tail guard rechecks
	WhenRaiser,    // parser: a body's `when (raiser) { … } else { … }` kept as an IfStmt; the Raiser lowering takes the consequent, every other backend the alternate
	LengthGuard,   // transform: the for-of lowering's tail guard that throws when the array's length changed during the step
	IntCheck,      // transform: a call intCheckInject made to check one integer operation; it reads and writes only its operands
	WritesOperand, // transform: a call that replaced a compound assignment or a step and writes its first argument in place
	PlainRelease,  // analyzer: this `new` runs a constructor and its class takes the plain decref, so a raise in the constructor releases the half-built object with it
}

// ===== Node Kind Enum =====

@builtin("MetaNodeKind")
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
	// `{ [key]: value }` whose key is not a string literal: compile-time only, like JSX.
	ComputedProperty,
}

// ===== Declaration Kind Enum =====

@builtin("MetaDeclKind")
export enum DeclKind {
	Const,
	Let,
	Var,
}

@builtin("MetaExternKind")
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

export function makeLoc(line: int32, column: int32): SourceLocation {
	return { line, column, endLine: 0 as int32, endColumn: 0 as int32 };
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
	| { operator: string, left: Owned<Node>, right: Owned<Node> }                // BinaryExpr
	| { unaryOp: string, operand: Owned<Node> }                           // UnaryExpr
	| { updateOp: string, updateArg: Owned<Node>, isPrefix: boolean }     // UpdateExpr (i++, ++i)
	| { callee: Owned<Node>, arguments: Owned<Node>[], isDirectCall: boolean, resolvedOverloadIdx: number }  // CallExpr
	| { object: Owned<Node>, property: string, isOptional: boolean }      // MemberExpr
	| { array: Owned<Node>, index: Owned<Node> }                                 // ArrayAccess
	| { properties: Owned<Node>[], keys: string[], keyLocations: SourceLocation[] } // ObjectLiteral
	| { elements: Owned<Node>[] }                                         // ArrayLiteral
	| { arrowParams: string[], arrowParamTypes: string[], arrowBody: Owned<Node>, arrowFlags: string, arrowReturnType: string, arrowDefaults: Owned<Node>[] } // ArrowFunction
	| { funcExprParams: string[], funcExprParamTypes: string[], funcExprBody: Owned<Node>, funcExprFlags: string, funcExprReturnType: string } // FunctionExpr
	| { asExpr: Owned<Node>, asType: string }                              // TypeAssertion
	| { ternaryCondition: Owned<Node>, ternaryConsequent: Owned<Node>, ternaryAlternate: Owned<Node> } // ConditionalExpr
	| { spreadArg: Owned<Node> }                                          // SpreadExpr
	| { newCallee: Owned<Node>, newArguments: Owned<Node>[] }                    // NewExpr
	| { tryArg: Owned<Node>, hasCatch: boolean, catchVal: Owned<Node> }          // TryExpr
	| { matchDisc: Owned<Node>, matchCases: Owned<Node>[] }                      // MatchExpr
	| { casePatterns: Owned<Node>[], caseGuard: Owned<Node> | null, caseBody: Owned<Node> }    // MatchCase
	| { awaitArg: Owned<Node> }                                           // AwaitExpr
	| { yieldArg: Owned<Node>, isDelegate: boolean }                      // YieldExpr
	| { moveArg: Owned<Node> }                                            // MoveExpr
	| { outArg: Owned<Node> }                                             // OutExpr
	| { sizeofType: string, sizeofResolved: Type | null }                 // SizeofExpr
	| { convExpr: Owned<Node>, convType: Type }                           // HiddenStdConv, HiddenSubConv
	| { expr: Owned<Node> }                                               // HiddenDeref, HiddenAddr
	| { annotationType: string }                                   // TypeAnnotation
	// Pattern variants
	| { patternElements: Owned<Node>[], hasRestElement: boolean, patternDefaults: Owned<Node>[] } // ArrayPattern
	| { patternProps: Owned<Node>[], hasRestProp: boolean }               // ObjectPattern
	| { propKey: string, propAlias: Owned<Node>, propDefault: Owned<Node> | null } // ObjectPatternProp
	| { destrPattern: Owned<Node>, destrInit: Owned<Node>, destrIsConst: boolean, destrType: string } // DestructuringDecl
	// Statement variants
	| { declName: string, declType: string, initializer: Owned<Node>, declKind: DeclKind, nameLocation: SourceLocation }  // VariableDecl
	| { condition: Owned<Node>, consequent: Owned<Node>, alternate: Owned<Node> }       // IfStmt
	| { whileCondition: Owned<Node>, whileBody: Owned<Node>, whileLabel: string } // WhileStmt
	| { forInit: Owned<Node>, forCondition: Owned<Node>, forUpdate: Owned<Node>, forBody: Owned<Node>, forLabel: string } // ForStmt
	| { forOfBinding: string, forOfIsConst: boolean, forOfIterable: Owned<Node>, forOfBody: Owned<Node>, forOfPattern: Owned<Node>, bindingLocation: SourceLocation, forOfLabel: string } // ForOfStmt
	| { forInBinding: string, forInIsConst: boolean, forInObject: Owned<Node>, forInBody: Owned<Node>, forInLabel: string } // ForInStmt
	| { statements: Owned<Node>[] }                                       // BlockStmt
	| { expr: Owned<Node> }                                               // ExprStmt
	| { argument: Owned<Node> | null }                                    // ReturnStmt
	| { breakLabel: string }                                       // BreakStmt
	| { continueLabel: string }                                    // ContinueStmt
	| { fnName: string, params: string[], fnParamTypes: string[], fnBody: Owned<Node>, fnFlags: string, fnReturnType: string, fnDefaults: Owned<Node>[], nativeName: string, nameLocation: SourceLocation } // FunctionDecl
	| { doBody: Owned<Node>, doCondition: Owned<Node>, dwLabel: string, dwSwitchWrapper: boolean } // DoWhileStmt
	| { switchDisc: Owned<Node>, switchCases: Owned<Node>[], switchLowered: boolean } // SwitchStmt
	| { caseTests: Owned<Node>[], caseStmts: Owned<Node>[], isDefault: boolean } // SwitchCase
	| { unreachableMsg: string }                                   // UnreachableStmt
	| { matchStmtDisc: Owned<Node>, matchStmtCases: Owned<Node>[] }              // MatchStmt
	// Declaration variants
	| { importNames: string[], importAliases: string[], importSource: string, nameLocations: SourceLocation[], aliasLocations: SourceLocation[], importTypeNames: string[] }  // ImportDecl
	| { exportedDecl: Owned<Node> }                                       // ExportDecl
	| { aliasName: string, aliasType: string, aliasIsDistinct: boolean, aliasGenericParams: string, discriminantName: string, discriminantType: string, variantKeys: string[], variantTypes: string[], nameLocation: SourceLocation } // TypeAliasDecl
	| { enumName: string, enumMembers: string[], enumValues: number[], nameLocation: SourceLocation, memberLocations: SourceLocation[], enumInits: Owned<Node>[] } // EnumDecl
	| { interfaceName: string, interfaceFields: string[], interfaceFieldTypes: string[], interfaceExtends: string[], nameLocation: SourceLocation, interfaceFieldVisibility: string[], interfaceFieldDecorators: Owned<Node>[][], interfaceOptionalFields: string[], nativeName: string } // InterfaceDecl
	| { interfaceName: string, interfaceFields: string[], interfaceFieldTypes: string[], interfaceExtends: string[], nameLocation: SourceLocation, interfaceFieldVisibility: string[], interfaceFieldDecorators: Owned<Node>[][], interfaceOptionalFields: string[], nativeName: string } // StructDecl
	| { className: string, classDisplayName: string, classExtends: string, classBody: Owned<Node>[], nameLocation: SourceLocation, classImplements: string[] } // ClassDecl
	| { propName: string, propType: string, propIsStatic: boolean, propIsReadonly: boolean, propVisibility: string, propInitializer: Owned<Node> }  // PropertyDecl
	| { methodName: string, methodParams: string[], methodParamTypes: string[], methodBody: Owned<Node>, methodIsStatic: boolean, methodFlags: string, methodVisibility: string, methodReturnType: string, methodDefaults: Owned<Node>[], nativeName: string, nameLocation: SourceLocation } // MethodDecl
	| { ctorParams: string[], ctorParamTypes: string[], ctorBody: Owned<Node>, ctorDefaults: Owned<Node>[], ctorVisibility: string, ctorParamProps: Owned<Node>[], ctorFlags: string } // ConstructorDecl
	// Error handling variants
	| { throwArg: Owned<Node> }                                           // ThrowStmt
	| { tryBody: Owned<Node>, catchName: string, catchBody: Owned<Node>, finallyBody: Owned<Node>, catchBindingLocation: SourceLocation, hasCatchClause: boolean } // TryCatchStmt
	// Decorator variants
	| { macroName: string, macroArgs: Owned<Node>[], macroHasParens: boolean }  // MacroInvocation
	| { decorators: Owned<Node>[], decoratedNode: Owned<Node> }                  // DecoratedDecl
	| { deferExpr: Owned<Node> }                                          // DeferStmt
	// Testing variants
	| { testName: string, testBody: Owned<Node> }                         // TestDecl
	| { assertExpr: Owned<Node>, assertSource: string, assertMessage: string, assertMessageExpr: Owned<Node> | null } // AssertStmt
	// Extern / Macro / Quote variants
	| { externKind: ExternKind, externName: string, nativeName: string, externType: string } // ExternDecl
	| { macroDeclName: string, macroDeclParams: string[], macroDeclParamTypes: string[], macroDeclReturnType: string, macroDeclBody: Owned<Node> } // MacroDecl
	| { quoteBody: Owned<Node> }                                          // QuoteExpr
	| { comptimeBody: Owned<Node> }                                       // ComptimeBlock
	// Type expression variants (positioned type AST — standard parity)
	// TypeName uses NodeKind.Identifier with { name: string } — reuses expression kind for type leaf nodes
	| { typExprBase: Owned<Node>, typExprArgs: Owned<Node>[] }                   // TypeGeneric
	| { typExprElement: Owned<Node>, typExprSize: number }                // TypeArray (-1 = unsized)
	// TypeUnion — discriminator metadata surfaced for tagged-union codecs (V3).
	// discFieldName="" + variantKeys=[] + discKind="" mean "no detectable disc"
	// (TS-style DUs auto-detected by codecs walking variants; match-type DUs
	// have these populated by bridge from Type.typeNames + typeExtra).
	// discKind ∈ {"boolean","enum",""} ("" = no disc / TS-style).
	| { typExprMembers: Owned<Node>[], discFieldName: string, variantKeys: string[], discKind: string }  // TypeUnion
	// TypeIntersection — same Node[] shape, no disc info (intersections aren't DUs).
	| { typExprMembers: Owned<Node>[] }                                   // TypeIntersection
	| { typExprParams: Owned<Node>[], typExprReturn: Owned<Node>, typExprParamNames: string[] } // TypeFunction
	| { typExprFieldNames: string[], typExprFieldTypes: Owned<Node>[], typExprIndexKey: Owned<Node>, typExprIndexValue: Owned<Node>, typExprFieldDecorators: Owned<Node>[][], typExprTypeName: string, typExprOptionalFields: string[] }   // TypeObject
	// Program root
	| { programStmts: Owned<Node>[] }                                     // Program
	// Actor (appended after Program to preserve union discriminant ordering)
	| { actorName: string, actorBody: Owned<Node>[], nameLocation: SourceLocation } // ActorDecl
	// SERIALIZE A2 — macro multi-decl emission
	| { spliceNodes: Owned<Node>[] }                                      // SpliceMany
	// JSX (appended at end to preserve union discriminant ordering)
	| { jsxTag: string, jsxAttrs: Owned<Node>[], jsxChildren: Owned<Node>[], jsxSelfClosing: boolean } // JSXElement
	| { jsxFragChildren: Owned<Node>[] }                                  // JSXFragment
	| { jsxText: string }                                          // JSXText
	| { jsxExpr: Owned<Node> }                                            // JSXExpressionContainer
	| { jsxAttrName: string, jsxAttrValue: Owned<Node> }                  // JSXAttribute
	| { jsxSpreadArg: Owned<Node> }                                       // JSXSpreadAttribute
	| { computedKey: Owned<Node>, computedValue: Owned<Node> }                  // ComputedProperty

// ===== Flow Graph =====
//
// A Control Flow Graph built by the binder pass between parse and check.
// Each reference expression (Identifier, MemberExpr, etc.) gets a `flowNode`
// pointing into this graph. The checker walks antecedents backward from the
// reference to compute a narrowed type at that program point.
//
// Single FlowNode struct with a FlowFlag set tag (NOT a sum type) —
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

export enum FlowFlag {
	Unreachable,
	Start,
	BranchLabel,
	LoopLabel,
	Assignment,
	TrueCondition,
	FalseCondition,
	SwitchClause,
	ArrayMutation,
	Call,
	ReduceLabel,
	Referenced,
	Shared,
}

// FlowList — singly-linked list of FlowNode antecedents for join labels.
// Duplicates are dropped at `addAntecedent` time (pointer-equality walk).
export class FlowList {
	flow: Unowned<FlowNode>;
	next: Owned<FlowList> | null;
}

// Synthetic node stored in FlowNode.node when Flags contains SwitchClause.
// Represents a half-open range of switch case clauses [clauseStart, clauseEnd).
// Coalesces empty-fallthrough clauses into one range for efficiency.
export class FlowSwitchClauseData {
	switchStatement: Unowned<Node>; // the SwitchStmt AST node
	clauseStart: int32;
	clauseEnd: int32;
}

// Synthetic node stored in FlowNode.node when Flags contains ReduceLabel.
// Used for try/finally re-routing: finally's antecedent set differs depending
// on whether analysis is for normal exit, return exit, or exception exit.
export class FlowReduceLabelData {
	target: Unowned<FlowNode>; // the LoopLabel/BranchLabel to re-route
	antecedents: FlowList;   // alternate antecedent set for this query context
}

export class FlowNode {
	flags: BitSet<FlowFlag>;
	node: Unowned<Node> | null;       // associated AST node (variant-dependent meaning; may be synthetic FlowSwitchClauseData / FlowReduceLabelData holder)
	antecedent: Owned<FlowNode> | null; // single parent (non-Label variants)
	antecedents: FlowList | null;   // list of parents (BranchLabel / LoopLabel only)
	// Synthetic variant holders (null unless Flags has SwitchClause / ReduceLabel)
	switchClauseData: FlowSwitchClauseData | null;
	reduceLabelData: FlowReduceLabelData | null;
}

// ===== Node Interface =====

@builtin("MetaNode")
export class Node {
	kind: NodeKind;
	location: SourceLocation;
	data: Owned<NodeData>;
	// Compiler-internal: the checker's resolved Type. MACRO BODIES see a
	// different shape here — the VM wire carries a type-AST Node tree
	// (TypeObject/TypeUnion/TypeArray/TypeGeneric/Identifier/literal kinds,
	// from mapTypeToAst), so the engine checker types `node.nodeType` as Node
	// and flat reads (.typExprFieldNames, .discFieldName, ...) resolve per the
	// NodeData unique-field-name rule (checkExprPass engine virtual props).
	nodeType: Type | null;
	resolvedSym: Symbol | null;
	flags: BitSet<NodeFlag>;
	variantSlot: int32;
	typeExpr: Owned<Node> | null;    // Positioned type annotation AST (standard parity: PNode type tree alongside string fields)
	typeExprs: Owned<Node>[] | null; // Per-param/per-field type annotation ASTs (parallel to string[] type fields). null entry = no annotation for that param.
	genericDefaults: (Owned<Node> | null)[] | null; // Aligned declaration TypeAnnotation wrappers; null entry means no default.
	baseExprs: Owned<Node>[] | null; // StructDecl/InterfaceDecl: one node per interfaceExtends entry, typed with the parent resolved in the declaring scope
	paramLocations: SourceLocation[] | null; // Per-param source locations for DEF recording
	paramSyms: Symbol[] | null;
	typeArg: string; // Use site: explicit generic args ("Person" from parse<Person>()); class/interface/struct/actor/extern decl: its generic params ("K,V")
	flowNode: FlowNode | null; // Flow graph node for narrowing queries. Null until binder runs; null for non-reference nodes.
	// Compiler-side round-trip slot mirrored here for wire parity: the compiler's
	// internal Node keeps nodeType as a checker Type, so valueToNode stores the
	// reconstructed type-AST in nodeTypeAst and nodeToASTLiteral falls back to it
	// for nested re-expansion. Macro bodies should read nodeType (above) — in the
	// VM heap that key always carries the type-AST Node.
	nodeTypeAst: Owned<Node> | null;
	inlineFrame: InlineFrame | null; // Compiler-side: the routine this node was copied from when a call to it was inlined; null for the routine's own code.
}

// A routine whose call was replaced by its body; `parent` is the inlined routine that called it, `callLine` the line of that call.
export class InlineFrame {
	name: string;
	parent: Owned<InlineFrame> | null;
	callLine: int32;
	constructor(name: string, parent: InlineFrame | null, callLine: int32) {
		this.name = name;
		this.parent = parent;
		this.callLine = callLine;
	}
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
export type BinaryExprData = { operator: string, left: Owned<Node>, right: Owned<Node> };
export type UnaryExprData = { unaryOp: string, operand: Owned<Node> };
export type UpdateExprData = { updateOp: string, updateArg: Owned<Node>, isPrefix: boolean };
export type CallExprData = { callee: Owned<Node>, arguments: Owned<Node>[], isDirectCall: boolean, resolvedOverloadIdx: number };
export type MemberExprData = { object: Owned<Node>, property: string, isOptional: boolean };
export type ArrayAccessData = { array: Owned<Node>, index: Owned<Node> };
export type ObjectLiteralData = { properties: Owned<Node>[], keys: string[], keyLocations: SourceLocation[] };
export type ArrayLiteralData = { elements: Owned<Node>[] };
export type ArrowFunctionData = { arrowParams: string[], arrowParamTypes: string[], arrowBody: Owned<Node>, arrowFlags: string, arrowReturnType: string, arrowDefaults: Owned<Node>[] };
export type FunctionExprData = { funcExprParams: string[], funcExprParamTypes: string[], funcExprBody: Owned<Node>, funcExprFlags: string, funcExprReturnType: string };
export type TypeAssertionData = { asExpr: Owned<Node>, asType: string };
export type ConditionalExprData = { ternaryCondition: Owned<Node>, ternaryConsequent: Owned<Node>, ternaryAlternate: Owned<Node> };
export type SpreadExprData = { spreadArg: Owned<Node> };
export type NewExprData = { newCallee: Owned<Node>, newArguments: Owned<Node>[] };
export type TryExprData = { tryArg: Owned<Node>, hasCatch: boolean, catchVal: Owned<Node> };
export type MatchExprData = { matchDisc: Owned<Node>, matchCases: Owned<Node>[] };
export type MatchCaseData = { casePatterns: Owned<Node>[], caseGuard: Owned<Node> | null, caseBody: Owned<Node> };
export type AwaitExprData = { awaitArg: Owned<Node> };
export type YieldExprData = { yieldArg: Owned<Node>, isDelegate: boolean };
export type MoveExprData = { moveArg: Owned<Node> };
export type OutExprData = { outArg: Owned<Node> };
export type SizeofExprData = { sizeofType: string, sizeofResolved: Type | null };
export type HiddenStdConvData = { convExpr: Owned<Node>, convType: Type };
export type TypeAnnotationData = { annotationType: string };

// Patterns
export type ArrayPatternData = { patternElements: Owned<Node>[], hasRestElement: boolean, patternDefaults: Owned<Node>[] };
export type ObjectPatternData = { patternProps: Owned<Node>[], hasRestProp: boolean };
export type ObjectPatternPropData = { propKey: string, propAlias: Owned<Node>, propDefault: Owned<Node> | null };
export type DestructuringDeclData = { destrPattern: Owned<Node>, destrInit: Owned<Node>, destrIsConst: boolean, destrType: string };

// Statements
export type VariableDeclData = { declName: string, declType: string, initializer: Owned<Node>, declKind: DeclKind, nameLocation: SourceLocation };
export type IfStmtData = { condition: Owned<Node>, consequent: Owned<Node>, alternate: Owned<Node> };
export type WhileStmtData = { whileCondition: Owned<Node>, whileBody: Owned<Node>, whileLabel: string };
export type ForStmtData = { forInit: Owned<Node>, forCondition: Owned<Node>, forUpdate: Owned<Node>, forBody: Owned<Node>, forLabel: string };
export type ForOfStmtData = { forOfBinding: string, forOfIsConst: boolean, forOfIterable: Owned<Node>, forOfBody: Owned<Node>, forOfPattern: Owned<Node>, bindingLocation: SourceLocation, forOfLabel: string };
export type ForInStmtData = { forInBinding: string, forInIsConst: boolean, forInObject: Owned<Node>, forInBody: Owned<Node>, forInLabel: string };
export type BlockStmtData = { statements: Owned<Node>[] };
export type ExprStmtData = { expr: Owned<Node> };
export type ReturnStmtData = { argument: Owned<Node> | null };
export type BreakStmtData = { breakLabel: string };
export type ContinueStmtData = { continueLabel: string };
export type FunctionDeclData = { fnName: string, params: string[], fnParamTypes: string[], fnBody: Owned<Node>, fnFlags: string, fnReturnType: string, fnDefaults: Owned<Node>[], nativeName: string, nameLocation: SourceLocation };
export type DoWhileStmtData = { doBody: Owned<Node>, doCondition: Owned<Node>, dwLabel: string, dwSwitchWrapper: boolean };
export type SwitchStmtData = { switchDisc: Owned<Node>, switchCases: Owned<Node>[], switchLowered: boolean };
export type SwitchCaseData = { caseTests: Owned<Node>[], caseStmts: Owned<Node>[], isDefault: boolean };
export type UnreachableStmtData = { unreachableMsg: string };
export type MatchStmtData = { matchStmtDisc: Owned<Node>, matchStmtCases: Owned<Node>[] };

// Declarations
export type ImportDeclData = { importNames: string[], importAliases: string[], importSource: string, nameLocations: SourceLocation[], aliasLocations: SourceLocation[], importTypeNames: string[] };
export type ExportDeclData = { exportedDecl: Owned<Node> };
export type TypeAliasDeclData = { aliasName: string, aliasType: string, aliasIsDistinct: boolean, aliasGenericParams: string, discriminantName: string, discriminantType: string, variantKeys: string[], variantTypes: string[], nameLocation: SourceLocation };
export type EnumDeclData = { enumName: string, enumMembers: string[], enumValues: number[], nameLocation: SourceLocation, memberLocations: SourceLocation[], enumInits: Owned<Node>[] };
export type InterfaceDeclData = { interfaceName: string, interfaceFields: string[], interfaceFieldTypes: string[], interfaceExtends: string[], nameLocation: SourceLocation, interfaceFieldVisibility: string[], interfaceFieldDecorators: Owned<Node>[][], interfaceOptionalFields: string[], nativeName: string };
export type StructDeclData = { interfaceName: string, interfaceFields: string[], interfaceFieldTypes: string[], interfaceExtends: string[], nameLocation: SourceLocation, interfaceFieldVisibility: string[], interfaceFieldDecorators: Owned<Node>[][], interfaceOptionalFields: string[], nativeName: string };
export type ClassDeclData = { className: string, classDisplayName: string, classExtends: string, classBody: Owned<Node>[], nameLocation: SourceLocation, classImplements: string[] };
export type ActorDeclData = { actorName: string, actorBody: Owned<Node>[], nameLocation: SourceLocation };
export type PropertyDeclData = { propName: string, propType: string, propIsStatic: boolean, propIsReadonly: boolean, propVisibility: string, propInitializer: Owned<Node> }; // propVisibility: "" | "public" | "private" | "protected"
export type MethodDeclData = { methodName: string, methodParams: string[], methodParamTypes: string[], methodBody: Owned<Node>, methodIsStatic: boolean, methodFlags: string, methodVisibility: string, methodReturnType: string, methodDefaults: Owned<Node>[], nativeName: string, nameLocation: SourceLocation };
export type ConstructorDeclData = { ctorParams: string[], ctorParamTypes: string[], ctorBody: Owned<Node>, ctorDefaults: Owned<Node>[], ctorVisibility: string, ctorParamProps: Owned<Node>[], ctorFlags: string }; // ctorParamProps: per parameter, the PropertyDecl a parameter property declares (propVisibility, propIsReadonly as written), null for a plain parameter
export type ExternDeclData = { externKind: ExternKind, externName: string, nativeName: string, externType: string };
export type MacroDeclData = { macroDeclName: string, macroDeclParams: string[], macroDeclParamTypes: string[], macroDeclReturnType: string, macroDeclBody: Owned<Node> };
export type DecoratedDeclData = { decorators: Owned<Node>[], decoratedNode: Owned<Node> };
export type ProgramData = { programStmts: Owned<Node>[] };
export type SpliceManyData = { spliceNodes: Owned<Node>[] };
export type DeferStmtData = { deferExpr: Owned<Node> };
export type ThrowStmtData = { throwArg: Owned<Node> };
export type TryCatchStmtData = { tryBody: Owned<Node>, catchName: string, catchBody: Owned<Node>, finallyBody: Owned<Node>, catchBindingLocation: SourceLocation, hasCatchClause: boolean };
export type MacroInvocationData = { macroName: string, macroArgs: Owned<Node>[], macroHasParens: boolean };
export type HiddenDerefData = { expr: Owned<Node> };
export type TestDeclData = { testName: string, testBody: Owned<Node> };
export type AssertStmtData = { assertExpr: Owned<Node>, assertSource: string, assertMessage: string, assertMessageExpr: Owned<Node> | null };
export type QuoteExprData = { quoteBody: Owned<Node> };
export type ComptimeBlockData = { comptimeBody: Owned<Node> };

// Type expression data types (positioned type AST — standard parity)
// Leaf type names use IdentifierData (NodeKind.Identifier) — reuses expression kind for type leaf nodes
export type TypeGenericData = { typExprBase: Owned<Node>, typExprArgs: Owned<Node>[] };
export type TypeArrayData = { typExprElement: Owned<Node>, typExprSize: number };
// TypeUnionData — variants + discriminator metadata (V3 tagged-union support).
// discFieldName/variantKeys/discKind populated only for match-type DUs (where
// disc info pre-stored in Type.typeNames + typeExtra). TS-style DUs leave them
// empty — codecs detect by walking variants (each variant struct has disc field).
export type TypeUnionData = {
	typExprMembers: Owned<Node>[],
	discFieldName: string,
	variantKeys: string[],
	discKind: string,
};
// TypeIntersectionData — same Node[] shape, no disc info (intersections aren't DUs).
export type TypeIntersectionData = { typExprMembers: Owned<Node>[] };
export type TypeFunctionData = { typExprParams: Owned<Node>[], typExprReturn: Owned<Node>, typExprParamNames: string[] };
// typExprIndexKey / typExprIndexValue are non-null ONLY when the type is an index signature
// like { [key: K]: V }. After checker normalization this becomes Map<K, V>. Mixed (named fields
// + index signature in the same type) is rejected by the parser. See docs and plan for details.
export type TypeObjectData = { typExprFieldNames: string[], typExprFieldTypes: Owned<Node>[], typExprIndexKey: Owned<Node>, typExprIndexValue: Owned<Node>, typExprFieldDecorators: Owned<Node>[][], typExprTypeName: string, typExprOptionalFields: string[] };

// JSX (compile-time only — erased by consuming macro before codegen)
export type JSXElementData = { jsxTag: string, jsxAttrs: Owned<Node>[], jsxChildren: Owned<Node>[], jsxSelfClosing: boolean };
export type JSXFragmentData = { jsxFragChildren: Owned<Node>[] };
export type JSXTextData = { jsxText: string };
export type JSXExpressionContainerData = { jsxExpr: Owned<Node> };
export type JSXAttributeData = { jsxAttrName: string, jsxAttrValue: Owned<Node> };
export type JSXSpreadAttributeData = { jsxSpreadArg: Owned<Node> };
export type ComputedPropertyData = { computedKey: Owned<Node>, computedValue: Owned<Node> };

// ===== Constructors =====

@builtin("MetaCreateNode")
export function createNode(kind: NodeKind, data: NodeData, token: Token): Node {
	return {
		kind,
		location: makeLoc(token.line, token.column),
		data,
		nodeType: null,
		resolvedSym: null,
		flags: 0 as BitSet<NodeFlag>,
		variantSlot: 0,
		typeExpr: null,
		typeExprs: null,
		genericDefaults: null,
		baseExprs: null,
		paramLocations: null,
		paramSyms: null,
		typeArg: "",
		flowNode: null,
		nodeTypeAst: null,
		inlineFrame: null,
	};
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
@builtin("MetaCreateNodeAt")
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
export function createNodeAt(kind: NodeKind.ComputedProperty, data: ComputedPropertyData, loc: SourceLocation): Node;

// Implementation — widest signature, accepts any NodeKind and the NodeData union.
// This is the body; all overload signatures above delegate here via the checker's
// overload resolution. It also serves as the fallback for callers that pass a
// runtime (non-literal) NodeKind or a NodeData value that isn't known to narrow.
@builtin("MetaCreateNodeAt")
export function createNodeAt(kind: NodeKind, data: NodeData, loc: SourceLocation): Node {
	return {
		kind,
		location: loc,
		data,
		nodeType: null,
		resolvedSym: null,
		flags: 0 as BitSet<NodeFlag>,
		variantSlot: 0,
		typeExpr: null,
		typeExprs: null,
		genericDefaults: null,
		baseExprs: null,
		paramLocations: null,
		paramSyms: null,
		typeArg: "",
		flowNode: null,
		nodeTypeAst: null,
		inlineFrame: null,
	};
}

export function isEmptyBlock(node: Readonly<Node>): boolean {
	if (node == null) return true;
	if (node.kind != NodeKind.BlockStmt) return false;
	const d = node.data as BlockStmtData;
	return d.statements.length == 0;
}

// Flatten a left-associative BinaryExpr(+) chain into its leaf nodes.
// Used by @emit template interpolation (checker) and string concat flattening (transform).
// Iterative stack approach (C-safe: avoids mutable array params).
export function collectConcatParts(node: Node): Node[] {
	const result: Node[] = [];
	const stack: Node[] = [node];
	while (stack.length > 0) {
		const cur = stack.pop();
		if (cur.kind == NodeKind.BinaryExpr) {
			const d = cur.data as BinaryExprData;
			if (d.operator == "+") {
				stack.push(d.right);
				stack.push(d.left);
				continue;
			}
		}
		result.push(cur);
	}
	return result;
}

// A symbol points back at nodes its declaration owns (its default values, decorators, meta values).
export function backEdges(nodes: Node[]): Unowned<Node>[] {
	const out: Unowned<Node>[] = [];
	for (const n of nodes) out.push(n);
	return out;
}

export function strongNodes(nodes: Unowned<Node>[]): Node[] {
	const out: Node[] = [];
	for (const n of nodes) out.push(n);
	return out;
}
