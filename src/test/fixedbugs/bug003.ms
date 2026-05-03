// bug003 — substituteType nulled GenericInstance.typeReturn without re-substituting
//
// Symptom:  Generic functions returning wrapped types like `Result<T, E>` produced
//           types where `typeChildren` were substituted but `typeReturn` (the
//           instantiated body) was nulled. Downstream `peelToStructOrUnion` fell
//           back to the un-substituted `typeExtra` base, leaking GenericParam
//           into narrowed variant access (`r.error: GenericParam(E)` instead of
//           the concrete `string`) and into class field types (`b.items: T[]`
//           with `T` unresolved).
//
// Root cause: `substituteType` GenericInstance arm in src/checker/types.ms
//             nulled `gi.typeReturn` after substituting `typeChildren`, expecting
//             callers to re-run `instantiateGenericBody`. `inferGenericReturn`
//             (the main call-inference path) did NOT, so most generic returns
//             saw the un-substituted body via the typeExtra fallback.
//
// Fix:        Substitute `typeReturn` recursively instead of nulling it. Pattern
//             parity with all other compound kinds (Array/Union/Function/Ref...).
//             Eliminates the need for use-site `substituteGenericArgsFromGI`
//             workarounds that were defensively patching the leak.

class Box<T> {
	items: T[];
	constructor(initial: T[]) { this.items = initial; }
}

function getBox(): Box<string> {
	return new Box<string>(["a", "b"]);
}

test "bug003: generic class field type substitutes through typeReturn" {
	// Pre-fix: b.items had GenericParam(T) in env-field typing → emitted void*.
	const b = getBox();
	const arr = b.items;
	assert arr.length === 2;
	assert arr[0] === "a";
}

function safeDiv(a: number, b: number): Result<number, string> {
	if (b === 0) return Result.err("zero");
	return Result.ok(a / b);
}

test "bug003: narrowed variant field has concrete error type" {
	// Pre-fix: r.error returned GenericParam(E) → string === comparison kept
	//         raw `==` instead of msStringEquals lowering.
	const r = safeDiv(10, 0);
	if (!r.ok) {
		assert r.error === "zero";
	}
}

test "bug003: numeric literal contextual T binds correctly" {
	// Pre-fix: r-1 inferred as int32 (literal default), Result.ok(r-1) bound
	//         T=int32 from arg, contextual T=number from declared return was
	//         ignored. Codegen emitted Result__int32_string assigned to
	//         Result__number_string slot — C compile error.
	function f(): Result<number, string> {
		let r = 0;
		return Result.ok(r - 1);
	}
	const got = f();
	if (got.ok) {
		assert got.value === -1;
	}
}
