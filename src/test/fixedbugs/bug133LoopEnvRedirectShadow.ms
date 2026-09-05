// bug133 — a loop-local capture's env redirect stayed active past the loop and
// hijacked a later same-named binding
//
// Symptom:    a function that captures a loop-local in a closure, and later
//             declares an unrelated variable with the SAME NAME, read that
//             later variable out of the per-iteration env instead of its own
//             storage — the write went to one env, the read came from another
//             cell nobody had written. Silent wrong value, no diagnostic, C
//             only (the JS backend does not lambda-lift). Widest blast radius
//             was the compiler itself: the link-object list in
//             src/compiler/compile.ms is built this way, so a self-hosted
//             build emitted a smeared object list and the next generation
//             failed to link with undefined symbols.
// Root cause: src/transform/lowering/lambdaLifting.ms — a loop-local capture
//             queues a redirect rewrite that drainPendingRewrites pushes onto
//             state.activeEnvRewrites. FunctionDecl and TestDecl both save and
//             restore that list around their bodies; WhileStmt/DoWhileStmt did
//             not, so the redirect outlived the loop that owned it and matched
//             any later binding spelling the same name.
// Fix:        the two loop arms save/restore activeEnvRewrites around the loop
//             body, the same scope discipline the function-level arms already
//             had. The redirect stays live for the whole iteration (per-loop
//             capture semantics unchanged) and is dropped at the loop boundary.
//
// Guarded end-to-end by corpus/programs/307-closureLoopShadow.ms; the
// per-iteration half is pinned by guard/tailrecClosureEnvAlias.ms.

type B133Thunk = () => string;

function b133Shadowed(): string {
	const names: string[] = ["a", "b", "c"];
	const fs: B133Thunk[] = [];
	for (const j of names) {
		fs.push(() => { return j; });
	}
	let out = "";
	let ci = 0;
	while (ci < names.length) {
		const j = names[ci];
		out = out + j;
		ci = ci + 1;
	}
	let cl = "";
	for (const f of fs) {
		cl = cl + f();
	}
	return out + "|" + cl;
}

function b133Renamed(): string {
	const names: string[] = ["a", "b", "c"];
	const fs: B133Thunk[] = [];
	for (const j of names) {
		fs.push(() => { return j; });
	}
	let out = "";
	let ci = 0;
	while (ci < names.length) {
		const k = names[ci];
		out = out + k;
		ci = ci + 1;
	}
	return out;
}

test "bug133: a later same-named binding keeps its own storage" {
	const got = b133Shadowed();
	assert got == "abc|abc";
}

test "bug133: renaming the later binding is unaffected" {
	assert b133Renamed() == "abc";
}

test "bug133: closures still snapshot their own iteration" {
	const names: string[] = ["x", "y"];
	const fs: B133Thunk[] = [];
	for (const s of names) {
		fs.push(() => { return s; });
	}
	let seen = "";
	for (const f of fs) {
		seen = seen + f();
	}
	assert seen == "xy";
}
