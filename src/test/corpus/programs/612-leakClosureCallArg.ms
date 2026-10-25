// @maxrss: 40
// @stdout: leak-closure-callarg acc=95
// note: a closure capturing a local, passed inline as a non-sink argument the callee stores, leaves no env behind: the callee copies the closure it keeps, and the frame owns the env it built (was 247MB @ 2M before the closure pair was typed).

interface Box { f: () => number; }

function wrap(fn: () => number): Box { return { f: fn }; }

function main(): void {
	let acc = 0;
	for (let i = 0; i < 2000000; i = i + 1) {
		const cap = i % 7;
		const b = wrap(() => cap + 1);
		acc = ((acc + b.f()) % 100) as int32;
	}
	console.log(`leak-closure-callarg acc=${acc}`);
}
main();
