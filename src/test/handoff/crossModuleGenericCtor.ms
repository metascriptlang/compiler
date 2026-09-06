// crossModuleGenericCtor — `new Generic<T>()` works from a module that only
// IMPORTS the class, for a specialization the defining module never uses.
//
// instantiateClassConstructor bailed on `classSym.declNode.kind !== ClassDecl`.
// An imported class symbol carries the ImportDecl (export deliberately drops
// class declaration nodes — re-resolving their member types in the importer's
// scope pollutes the type registry), so the bail fired for every cross-module
// `new`, silently: no instance was ever queued, codegen still emitted the call
// plus a forward declaration, and the failure surfaced only at link time as
// `undefined symbol: <Class>__<T>_init` (neon flow: Signal__boolean,
// Signal__ref_arr_unknown via createMemo). It looked like it worked whenever
// the defining module happened to instantiate the same specialization itself —
// which is why Signal<number> linked and Signal<boolean> did not.
// Fix: reach the real ClassDecl through the defining module's checker ctx
// (pickBodyCtx / _moduleCtxMap), the same bridge this function already uses to
// re-check the constructor body. Nim parity: generateInstance copies the AST
// off the generic symbol itself (seminst.nim `copyTree(fn.ast)`) and adds the
// producer as a friend module — the instantiator always reaches the source.

import { GcCell, gcMakeNumber } from "./fixtures/genericCtorLib";


test "specialization only the importer asks for links" {
	const flag = new GcCell<boolean>(true);
	assert flag.value, "boolean cell";
}

// NOTE: a STRUCT type argument (`new GcCell<CmgTag>({ label: "x" })`) still fails, and
// not for this reason: the ctor's forward declaration takes `CmgTag*` while the call
// site passes the literal by value. That is the ctor-param proto/def indirection
// sibling (same shape as the known union-param mismatch), pre-existing and orthogonal
// to reaching the class declaration across modules — it is simply reachable now that
// cross-module ctors are instantiated at all.

// NOTE: `new GcCell<number[]>([1, 2, 3])` is deliberately absent — an ARRAY type
// argument makes the generated ctor take `msNumberArray*` while the call site passes
// a value, a separate by-pointer/by-value parameter-indirection bug (sibling of the
// union ctor-param proto/def mismatch), not the cross-module instantiation this guards.
test "string specialization from the importer" {
	const names = new GcCell<string>("neon");
	assert names.value == "neon", "string cell";
}

test "the defining module's own specialization still works" {
	const n = gcMakeNumber();
	assert n.value == 41, "number cell from the definer";
	const mine = new GcCell<number>(7);
	assert mine.value == 7, "same specialization from the importer";
}
