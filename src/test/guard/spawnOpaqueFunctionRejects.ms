// A spawn that hands an opaque function value to a routine that calls or stores it stays refused
//
// INVARIANT (ULTRALOCK module state): only an identity comparison of the parameter is inert
//   (spawnListenRuns.ms). A callee that calls the value, or compares it and also calls it, runs
//   code the checker cannot see on the worker, and a module-level closure table is such a value.
//
// RED MEANS: the inert-parameter exemption in effects.ms (onlyCompared) admits more than a comparison.
//
// GUARD-CHECK-FAIL passes a function value

let hook: () => int32 = (): int32 => 1;

function callIt(f: () => int32): int32 {
	return f();
}

function compareThenCall(f: () => int32, g: () => int32): int32 {
	if (f === g) return 0;
	return f();
}

function viaCall(): int32 {
	return callIt(hook);
}

function viaBoth(): int32 {
	return compareThenCall(hook, hook);
}

const a = await spawn(() => viaCall()); // GUARD-REFUSED
const b = await spawn(() => viaBoth()); // GUARD-REFUSED
