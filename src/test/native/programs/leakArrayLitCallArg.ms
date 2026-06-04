// leak-arraylit-callarg — fresh ARRAY literal as a stored call argument (the ArrayLiteral sibling
// of leak-callarg-object). A fresh array literal `[...]` passed inline as a non-sink call arg that
// the callee stores leaked the array SHELL (value stuck at rc=0): MS arrays are reference types
// (heap, ref-counted), so a fresh array literal is an owned heap value — unlike Nim's value-type
// bracket, which is why this was wrongly skipped at first.
//
// The RC string ELEMENTS make this ALSO an over-free guard: the fix sinks the elements into the
// array (owned) AND captures the shell for scope-exit destroy. If a fix captured the shell while
// leaving the elements borrowed, the shell's destroy would decref a borrowed element → over-free
// (SIGSEGV). So this case discriminates the correct fix (flat, exit 0) from no-fix (LEAK, 124MB)
// AND from a naive shell-only fix (SIGSEGV).
//
// FIXED by inject.ms processArrayLiteral: elements always SinkArg + Normal-mode ensureDestruction
// (Reference parity injectdestructors:889, adapted for heap-owned MS arrays). Now flat ~2MB.

interface Box { xs: string[]; }

function wrap(a: string[]): Box { return { xs: a }; }

function main(): void {
	let acc = 0;
	for (let i = 0; i < 2000000; i = i + 1) {
		const b = wrap([`ab${i}`, `cd${i}`]);
		acc = (acc + b.xs.length) % 100;
	}
	console.log(`leak-arraylit-callarg acc=${acc}`);
}
main();
