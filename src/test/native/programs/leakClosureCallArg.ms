// leak-closure-callarg — fresh CLOSURE (the 5th fresh-owned producer) as a stored call argument.
// A closure capturing a local has a heap env; passed inline as a non-sink call arg the callee
// stores, the closure thunk (an NF_CLOSURE ObjectLiteral whose type is TypeKind.Function) leaked
// because classify.ms treated ALL TypeKind.Function as needsCleanup=false (conservative, to keep
// bare function references safe). Heap closures with a captured env therefore never got
// msClosureDestroy → 247MB @ 2M.
//
// FIXED: classify.ms Function → needsCleanup=true. msClosureDestroy is null-env-safe
// (core/system.h: `if (env != NULL) msDecref(env)`), so bare-fn closures (env=NULL) no-op while
// env-bearing closures decref their env. The closure thunk is an ObjectLiteral, so the consolidated
// processNode capture handles it like any other fresh-owned producer. Now flat ~2MB, no over-free.

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
