// bug040 — `return obj.field` / `return arr[i]` leaked the container
//
// Symptom:    Any function that returned a field of a local RC-typed container
//             leaked the container + its transitively-held heap fields. The
//             leak was invisible to existing tests (correctness was unaffected,
//             only memory grew). Visible at scale: Photon WS broadcast leaked
//             ~5 MB / 100K deliveries because the lowered async fn body emits
//             `return env.$retFut`, hitting this exact pattern.
//
// Root cause: src/analyzer/inject.ms `markReturnedVarsMoved` walked the
//             OBJECT of MemberExpr / ARRAY of ArrayAccess, marking them
//             as moved. Scope-exit cleanup then emitted `msPtrWasMoved(obj)`
//             instead of `msDecref(obj)` — the container's `destroyFn`
//             never fires, leaking the heap data of every RC-tracked field.
//
// Fix:        Make MemberExpr / ArrayAccess arms in `markReturnedVarsMoved`
//             no-op. The field/element extraction does NOT transfer
//             ownership of the container; the container must follow the
//             normal scope-exit `=destroy` path.
//
// Reference:  Probed across 5 patterns; same mechanism affects all of
//             `return o.inner.x` (nested chain), `return arr[i]` (default
//             arm descended into ArrayAccess), `return move obj.field`,
//             and `return env.$retFut` (async fn lowering). Container can
//             be interface, struct, array, or class.

interface Bug040Box { value: number; payload: string; }
function bug040_returnFieldNoLeak(): number {
	const b: Bug040Box = { value: 42, payload: "padding to make sure heap allocation" };
	return b.value;
}

interface Bug040Outer { inner: Bug040Box; tag: string; }
function bug040_returnNestedField(): number {
	const o: Bug040Outer = { inner: { value: 7, payload: "x" }, tag: "outer" };
	return o.inner.value;
}

function bug040_returnArrayElem(): number {
	const arr: number[] = [10, 20, 30];
	return arr[1];
}

test "bug040: return obj.field doesn't leak container" {
	assert bug040_returnFieldNoLeak() === 42;
}

test "bug040: return nested field doesn't leak intermediate containers" {
	assert bug040_returnNestedField() === 7;
}

test "bug040: return arr[i] doesn't leak array" {
	assert bug040_returnArrayElem() === 20;
}
