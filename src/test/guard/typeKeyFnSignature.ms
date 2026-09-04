// nim-guard: structural type-dedup keys — function signature survival
//
// INVARIANT (Nim): type identity is STRUCTURAL — two wrappers over differently
//   signed procs are DISTINCT types. `hashType` (sighashes.nim:227, `of tyProc`)
//   folds each param name+type + return + callConv into the type hash used for
//   caching/mangling; `sameInstantiation` (seminst.nim:78) compares generic
//   type-args via `sameType`, which for tyProc compares params+return. A dedup
//   key must never drop the signature.
// NIM-REF: §1 "Structural type-dedup keys — function signature" — verdict was
//   DIVERGE-UNINTENTIONAL -> SAME (our own codegen typeKey already keyed fns
//   structurally; the checker keyers + anonFieldKey were the outliers).
//
// WHAT IT CATCHES: `maybeCacheKey` / checker `typeKey` collapsed EVERY function
//   to "p<kindOrdinal>" / kind.toString(), so `(()=>number)|null` and
//   `((v:number)=>void)|null` both keyed `Maybe_p22` -> the 2nd nullable-fn
//   field inherited the 1st's arity-0 signature -> "expected at most 0, got 1"
//   (fix 785065a). Same key feeds tuple names (tupleTypeName) and anon-struct
//   names (anonTypeName via anonFieldKey), so a drift there collides those too.
//
// RED MEANS: a type-dedup keyer dropped the function signature -> distinct
//   nullable-fn fields collapsed to one Maybe type, erasing arity. This probe
//   fails to BUILD (checker "expected at most 0") or throws on wrong value.
//   Run /trace-nim on maybeCacheKey / typeKey (checker/types.ms).
//
// GAP (not guarded here): the sibling `monoTypeKey` (registry.ms) collapse is
//   NOT covered — its fn case is BENIGN (msClosure is a uniform repr, arity is
//   applied at the call site, so a collapsed `Holder__function` still runs
//   correct), and its only RED case (anon-union type-arg fused -> incompatible
//   msUnion payloads) currently can't compile clean because of a separate
//   union ctor-param proto/def indirection bug + generic-fn-over-union bug.
//   Add a monoTypeKey union guard once those land (both logged in neon BUGS.md).
//
// Two nullable-fn fields of DIFFERENT arity are required; a single field or a
// non-nullable field does not collide. No RC balance directive — the signal is
// build-failure / wrong-value-throw, not a lifecycle count.
// Run by src/test/guard/run.sh with -DMS_DRC_LEDGER (drc + orc).

interface Cell {
	getter: (() => number) | null;
	setter: ((v: number) => void) | null;
}

function main(): void {
	let stored = 0;
	const cell: Cell = { getter: null, setter: null };
	cell.getter = () => 42;
	cell.setter = (v: number) => { stored = v as int32; };

	let got = 0;
	if (cell.getter !== null) { got = cell.getter() as int32; }
	if (cell.setter !== null) { cell.setter(7); }

	if (got !== 42) { throw "GUARD RED: getter signature dropped (arity-0 collision)"; }
	if (stored !== 7) { throw "GUARD RED: setter signature dropped (arity-0 collision)"; }
	console.log("typeKeyFnSignature ok");
}

main();
