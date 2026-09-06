// nim-guard: Maybe identity survives type substitution (Root B)
//
// INVARIANT (Nim): substituting type-vars into a type PRESERVES the type's
//   identity — `handleGenericInvocation` copies via `copyType` (semtypinst.nim:394)
//   then `result.flags = header.flags` (:451) + `result.flags + newbody.flags -
//   tfInstClearedFlags` (:489). Instantiation NEVER rebuilds a type through a
//   ctor that recomputes its flags from scratch, so `Option[T]` -> `Option[int]`
//   keeps its kind + identity flags.
// NIM-REF: §1 "Maybe identity survival across type substitution" — verdict was
//   DIVERGE-UNINTENTIONAL -> SAME (the Union case already re-canonicalized via
//   createMaybeType; the Struct case in substituteStruct was the lone outlier).
//
// WHAT IT CATCHES: `substituteStruct` (checker/types.ms:1701) rebuilt a
//   substituted Maybe via the generic `createStruct` ctor, which DROPPED IsMaybe
//   (recomputed only structural flags) and copied the stale unsubstituted
//   typeName (`Maybe_fn_fnTT…`). Downstream isMaybeType->false -> operatorLower
//   folds `equals !== null` to constant-true (guard VANISHES) + nullableLower
//   never unwraps -> `equals(a,b)` calls a struct (fix ba6b365).
//
// RED MEANS: substitution lost the Maybe's IsMaybe identity -> the null-guard on
//   a generic nullable-fn param folds away and/or the call is not unwrapped to
//   `.value.fn`. This probe fails to BUILD ("`Maybe_fn_fnTTboolean…` is not a
//   function"; the stale name still carries the raw `T`) or throws on a wrong
//   value. Run /trace-nim on substituteStruct (checker/types.ms).
//   Proven RED on a pre-fix binary; GREEN post-fix (drc + orc).
//
// SHAPE: mirrors createMemo's WORKING shape exactly — an OPTIONAL generic
//   nullable-fn param (`equals = null`), T bound from a `() => T` producer,
//   untyped arrow params. (The general "arrow -> REQUIRED generic Maybe<fn>
//   param" is still blocked by separate siblings — neon probe/nullfn_*.) No RC
//   balance directive; the signal is build-failure / wrong-value-throw.
// Run by src/test/guard/run.sh with -DMS_DRC_LEDGER (drc + orc).

function memoApply<T>(produce: () => T, equals: ((a: T, b: T) => boolean) | null = null): boolean {
	const a = produce();
	const b = produce();
	// Root B: `equals !== null` MUST survive substitution (not fold constant-true),
	// and `equals(a, b)` MUST unwrap to the Maybe's `.value.fn`, not call a struct.
	if (equals != null && equals(a, b)) {
		return true;
	}
	return false;
}

function main(): void {
	// null-default path: guard must hold; if IsMaybe is dropped it folds true and
	// `equals(a,b)` invokes a zeroed struct -> build fail / crash.
	const nullPath = memoApply(() => 7);
	// present-arrow paths (untyped params): call-site wrap + unwrap, result flows.
	const eqTrue = memoApply(() => 7, (a, b) => a == b);
	const eqFalse = memoApply(() => 7, (a, b) => a != b);

	if (nullPath != false) { throw "GUARD RED: null-equals guard vanished (IsMaybe dropped)"; }
	if (eqTrue != true) { throw "GUARD RED: present-equals not unwrapped (true arm)"; }
	if (eqFalse != false) { throw "GUARD RED: present-equals result not flowing (false arm)"; }
	console.log("maybeIdentitySubst ok");
}

main();
