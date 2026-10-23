// A closure moved into a spawn is refused when the thunk calls it
//
// INVARIANT (ULTRALOCK V0): a callee the checker cannot see counts as reaching module state, so a
//   call through a function value inside a crossing is a compile error naming the call. A closure
//   built by a factory and moved into the thunk is such a value.
//
// WHAT IT CATCHES: two factory-built closures returning strings, each moved into a slot of one spawn group and called there.
//
// RED MEANS: the thunk check in checkSpawnCaptures (sendable.ms) or callEffect (effects.ms) lets a
//   call through a moved function value cross.
//
// GUARD-CHECK-FAIL spawn runs this thunk on another thread, but it calls a function value at 23:45
// GUARD-CHECK-FAIL spawn runs this thunk on another thread, but it calls a function value at 23:78

function label(n: int32): () => string {
	const parts: string[] = [`p${n}`];
	return (): string => parts[0];
}

async function both(): Promise<string> {
	const a = label(1);
	const b = label(2);
	const rs = await Promise.all([spawn(() => a(), { move: [a] }), spawn(() => b(), { move: [b] })]);
	return `${rs[0]} ${rs[1]}`;
}

console.log(await both());
