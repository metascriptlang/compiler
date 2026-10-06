// @stdout: ab ab xy.xz.yy.yz. 012 135 m1n2
// note: a closure made in a loop body reads the binding of its own iteration: a for-of binding inside a function and at module level, the bindings of two nested loops, a `for (let …)` counter, a body local of a loop that continues, and a body local changed after the capture. Before, the Raiser lifted the closure without the loop binding ("cannot evaluate 'j' at comptime") or gave every iteration one shared env.
type Thunk = () => string;

function joinAll(fs: Thunk[], sep: string): string {
	let out = "";
	for (const f of fs) out = out + f() + sep;
	return out;
}

function forOfBinding(): string {
	const fs: Thunk[] = [];
	for (const j of ["a", "b"]) {
		fs.push(() => j);
	}
	return joinAll(fs, "");
}

const top: Thunk[] = [];
for (const j of ["a", "b"]) {
	top.push(() => j);
}

function nested(): string {
	const fs: Thunk[] = [];
	for (const a of ["x", "y"]) {
		for (const b of ["y", "z"]) {
			fs.push(() => a + b);
		}
	}
	return joinAll(fs, ".");
}

function counter(): string {
	const fs: Thunk[] = [];
	for (let i = 0; i < 3; i++) {
		fs.push(() => i.toString());
	}
	return joinAll(fs, "");
}

function continued(): string {
	const fs: Thunk[] = [];
	for (let i = 0; i < 6; i++) {
		if (i % 2 == 0) continue;
		const v = i;
		fs.push(() => v.toString());
	}
	return joinAll(fs, "");
}

function changedAfterCapture(): string {
	const fs: Thunk[] = [];
	let n = 0;
	for (const s of ["m", "n"]) {
		n = n + 1;
		let t = s;
		fs.push(() => t);
		t = t + n.toString();
	}
	return joinAll(fs, "");
}

console.log(`${forOfBinding()} ${joinAll(top, "")} ${nested()} ${counter()} ${continued()} ${changedAfterCapture()}`);
