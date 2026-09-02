// @stdout: fn-value ok
//
// A named function flowing into a VALUE slot must take the closure
// representation on both sides of the slot — store and call — on both
// backends. Nim keeps two representations (nimcall pointer vs closure pair,
// jsgen.nim:2971 nkClosure / ccgcalls.nim:515 genClosureCall); MS has one
// (msClosure, NIM-REF row 81 DIVERGE-INTENTIONAL), so the value-form of a
// bare function is always the pair on C and always the bare function on JS.
// Pre-fix: inferred const broke C (raw fn ptr into msClosure), and every
// annotated slot broke JS ({fn, env} record called as a function).

type Sel = { size?: string };

function pick(s: Sel): string {
	return s.size === null ? "-" : s.size;
}

type Sheet = { btn: (s: Sel) => string };

function make(): (s: Sel) => string {
	return pick;
}

function main(): void {
	const bare = pick;
	const annotated: (s: Sel) => string = pick;
	const sheet: Sheet = { btn: pick };
	const returned = make();
	const got = bare({ size: "a" }) + annotated({ size: "b" })
		+ sheet.btn({ size: "c" }) + returned({ size: "d" }) + bare({});
	if (got === "abcd-") {
		console.log("fn-value ok");
	} else {
		console.log("fn-value BAD: " + got);
	}
}

main();
