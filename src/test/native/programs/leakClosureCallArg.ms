// leak-closure-callarg — fresh CLOSURE (the 5th fresh-owned producer) as a stored call argument.
// A closure capturing a local has a heap env; passed inline as a non-sink call arg the callee
// stores, the closure thunk (an NF_CLOSURE ObjectLiteral whose type is TypeKind.Function) leaked
// because classify.ms treated ALL TypeKind.Function as needsCleanup=false (conservative, to keep
// bare function references safe). Heap closures with a captured env therefore never got
// msClosureDestroy → 247MB @ 2M.
//
// FIXED (3-part, traced by emit-C): (1) lambdaLifting sets the lifted closure-pair's nodeType so the
// analyzer can classify it (it was null → ensureDestructionIfNeeded bailed); (2) classify.ms Function
// → needsCleanup=true so the pair is captured + msClosureDestroy'd; (3) processObjectLiteral keeps
// NF_CLOSURE pairs isRefConstr so the env field stays a COPY (incref) — else nodeType=Function flips
// it to a borrow and the destroy double-frees the env against the env-var's own lifecycle. Balanced:
// env-var owns + each closure-holder increfs/decrefs. msClosureDestroy is null-env-safe so bare-fn
// closures (env=NULL) no-op. Now flat ~2MB, no over-free (paralock + self-host green).

interface Box { f: () => number; }

function wrap(fn: () => number): Box { return { f: fn }; }

function main(): void {
	let acc = 0;
	for (let i = 0; i < 2000000; i = i + 1) {
		const cap = i % 7;
		const b = wrap(() => cap + 1);
		acc = (acc + b.f()) % 100;
	}
	console.log(`leak-closure-callarg acc=${acc}`);
}
main();
