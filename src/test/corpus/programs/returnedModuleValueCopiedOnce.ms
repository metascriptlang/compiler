// @stdout: 60 3 1 7 9
// note: returning a module-level value gives the caller one copy, whether the return sits in a branch, in a loop or in a try with a finally, and for a struct holding an array and an object, a bare array and an object; the module value keeps its own and is released once at exit. Same output on every lane.
class Tag {
	n: int32;
	constructor(n: int32) { this.n = n; }
}
struct Plan { exe: string; args: string[]; tag: Tag; }

const NONE: Plan = { exe: "n" + "o", args: ["a" + "b"], tag: new Tag(7) };
const NAMES: string[] = ["x" + "y"];
const SHARED: Tag = new Tag(9);
let finals = 0;

function inBranch(bad: boolean): Plan {
	if (bad) return NONE;
	return { exe: "e", args: [], tag: new Tag(1) };
}
function inLoop(n: int32): Plan {
	for (let i = 0; i < n; i++) {
		if (i == 2) return NONE;
	}
	return { exe: "l", args: [], tag: new Tag(2) };
}
function inTry(n: int32): Plan {
	try {
		if (n > 0) return NONE;
		return { exe: "t", args: [], tag: new Tag(3) };
	} finally {
		finals += 1;
	}
}
function names(): string[] { return NAMES; }
function shared(): Tag { return SHARED; }

let total = 0;
for (let i = 0; i < 3; i++) {
	const a = inBranch(true);
	const b = inLoop(5);
	const c = inTry(1);
	const d = names();
	const e = shared();
	total += a.args.length + b.tag.n + c.exe.length + d.length + e.n;
}
console.log(`${total} ${finals} ${NONE.args.length} ${NONE.tag.n} ${SHARED.n}`);
