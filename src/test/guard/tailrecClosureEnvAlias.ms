// Nim's lambdalifting puts an env at the scope that DECLARES a captured
// variable, so a mutated capture has exactly one home. Tail-call lowering
// rewrites self-recursion into `while (1)`, which drops every body-scope local
// inside a loop body — if the lifter then snapshots such a local into a
// per-closure env while the enclosing code keeps reading the function-wide
// shared env, the closure's write lands on a copy and is silently lost.
// GUARD-JS

function run(cb: () => void): void { cb(); }

function ssr(depth: int32, flag: boolean): string {
	if (depth > 0) { return ssr(depth - 1, flag); }
	if (flag) {
		let out = "";
		run(() => { out = "inner"; });
		return out;
	}
	return "none";
}

type Thunk = () => int32;

function perIteration(): int32[] {
	const fns: Thunk[] = [];
	for (let i = 0; i < 2; i += 1) {
		let cell = i;
		const f = () => { cell = cell + 10; return cell; };
		cell = cell + 100;
		fns.push(f);
	}
	const got: int32[] = [];
	for (const f of fns) { got.push(f()); }
	return got;
}

function main(): void {
	const a = ssr(2, true);
	console.log("tailrec-capture=" + a);
	const b = perIteration();
	console.log("per-iteration=" + b[0].toString() + "," + b[1].toString());
	if (a !== "inner") { throw "GUARD RED: closure write to a tail-call-loop local was lost, got=" + a; }
	if (b[0] !== 110 || b[1] !== 111) { throw "GUARD RED: per-iteration cell diverged from the enclosing loop body, got=" + b[0].toString() + "," + b[1].toString(); }
	console.log("GUARD-OK");
}
main();
