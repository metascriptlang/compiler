// A spawn result that is dropped, never awaited, or awaited in a loop is refused
//
// INVARIANT (ULTRALOCK T1): every spawn result is awaited exactly once, in the scope that
//   created it. A discarded result leaves borrowed captures dangling; an unawaited binding
//   drops the result at scope exit; an outer handle awaited in a loop is reused on iteration 2.
//
// WHAT IT CATCHES: the three affine-tracker refusals that spawnHandleAnnotatedRejects does not
//   name (R1/E1, R1/E2, R1/E3 loop reuse) going silent.
//
// RED MEANS: one of the three refusals stopped firing, or was retagged.
//
// GUARD-JS
// GUARD-CHECK-FAIL spawn result is discarded — every affine Promise must be awaited
// GUARD-CHECK-FAIL affine Promise 'idle' from spawn(...) is never awaited
// GUARD-CHECK-FAIL affine Promise 'looped' from spawn(...) is consumed inside a loop body

function work(): int32 { return 1; }

function discarded(): void {
	spawn(work); // GUARD-REFUSED
}

function neverAwaited(): int32 {
	const idle = spawn(work); // GUARD-REFUSED
	return 0;
}

function awaitedInLoop(): int32 {
	const looped = spawn(work);
	let s: int32 = 0;
	for (let i = 0; i < 2; i += 1) s += await looped; // GUARD-REFUSED
	return s;
}

discarded();
console.log(neverAwaited());
console.log(awaitedInLoop());
