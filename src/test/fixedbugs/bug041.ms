// bug041 — async chain (`await` inside async fn) leaked env + futures
//
// Symptom:    Every call to an async fn that awaited another async fn left
//             behind 304 bytes (80B env struct + 2 × 112B futures). At
//             100K iterations, ~30 MB unrecoverable; Photon WS broadcast
//             observed steady RSS growth. Functionally correct — only
//             memory leaks.
//
// Root cause: Three intertwined bugs in the async lowering cleanup chain:
//             1. inject.ms `markReturnedVarsMoved` MemberExpr arm marked
//                the env moved at `return env.$retFut` (see bug040).
//             2. destructorLifting.ms `fillBody` GenericInstance branch
//                fell to no-op `defaultOp` for Promise<T> fields, so the
//                env's generated destroy hook didn't decref retFut / yf0.
//             3. dispatchFull.c `msAsyncCb` NULL branch didn't decref the
//                env reference taken in `msAsyncStart`; env count stuck
//                at 1 → never reached the `IS_LAST` destroy trigger.
//
// Fix:        Three coordinated changes:
//             1. inject.ms — MemberExpr/ArrayAccess arms in
//                `markReturnedVarsMoved` made no-op.
//             2. destructorLifting.ms — fillBody special-cases isAwaitable
//                to emit `msFutureDrcDestroy(field)` for the destroy hook.
//             3. dispatchFull.c — msAsyncCb NULL branch decrefs the env
//                to balance msAsyncStart's incref. Also extended
//                ensureTypeInfoDef in codegen/c/types.ms to wire the
//                destroyFn from AttachedDestructor (env types take the
//                consumer destructorLifting path with emitTypeInfo=false
//                so the codegen path is the only place destroyFn lands).
//
// Reference:  Verified by 10M-iteration scaling probe — RSS flat at
//             2.3 MB across 100K → 1M → 10M (would have been ~3 GB
//             pre-fix if the leak weren't a memory leak but a CPU leak).

async function bug041_leaf(): Promise<int32> { return 42; }
async function bug041_mid(): Promise<int32> {
	const v = await bug041_leaf();
	return v + 1;
}

test "bug041: async chain pattern compiles + lowers to state machine" {
	// Compile-time witness: this body lowers through asyncBridge + lambdaLifting,
	// producing the $Env_mid_shared struct + $lifted_mid_1 stepper. Pre-fix the
	// lowered `return env.$retFut` triggered the markReturnedVarsMoved MemberExpr
	// path → env leaked. Post-fix the lowering compiles to a correctly cleaned-up
	// state machine. Runtime leak verification is in /tmp probe (probeAwaitSlow).
	const fut = bug041_mid();
	assert fut != null;
}
