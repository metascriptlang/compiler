// nim-guard: an error a C-only transform pass reports stops the build at its line.
//
// Nim: every phase reports through localError(conf, info, ...) (msgs.nim:648).
//
// RED MEANS bigIntOpLower's refusal went unread after transformForNative: the
// build carries on and the C compiler rejects `b++` on an msBigInt pointer.
//
// GUARD-CHECK-FAIL increment/decrement on bigint is only supported as a statement
// GUARD-CHECK-FAIL nativeTransformErrorStopsBuild.ms:13:

function run(): void {
	let b = 5n;
	const c = (b++) + 1n;
	console.log(c.toString() + " " + b.toString());
}

run();
