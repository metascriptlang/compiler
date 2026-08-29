// nim-guard: returning a closure-captured `T | null` local must copy (+1) before
// env teardown decrefs the field. Nim parity: lowerings.nim indirectAccess types
// env access with field.typ (declared, never flow-narrowed); injectdestructors
// then copies `result = env.field`. Regression shape guarded: checker narrows a
// `= null` init to TypeKind.Null, lambdaLifting keeps the narrowed stamp on the
// lifted env read, DRC classifies it inert, the return skips incref — each call
// double-claims one ref and the ledger aborts on the second finalize.

interface Thing { v: int32; }

function apply(cb: (n: int32) => void): void {
	cb(1);
}

function findCaptured(): Thing | null {
	let found: Thing | null = null;
	apply((n: int32): void => {
		if (found === null) { found = { v: n }; }
	});
	return found;
}

function main(): void {
	const seed: Thing = { v: 1 };
	const results: Thing[] = [seed];
	for (let i = 0; i < 8; i += 1) {
		const r = findCaptured();
		if (r !== null) { results.push(r); }
	}
	let sum: int32 = 0;
	for (const t of results) { sum += t.v; }
	if (sum !== 9) { throw "GUARD RED: expected sum 9, got " + sum; }
	console.log("GUARD-OK");
}

main();
