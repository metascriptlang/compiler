// @stdout: vm-generic 1,2,3|a,b,c|9
// @exit: 0
// note: a macro body that sorts calls the std generic `sortBy`, whose home in the compile-time VM is the VM's own std (`index.rms`). That instance belongs to the VM: the program the build emits has no module to hold it, and handing it to one is an internal error. A generic declared in this program and called from a macro body is the other case — its home is a module of the build, so its instance goes with that module on every backend.

import { Node, NodeKind } from "std/meta";

function largest<T>(xs: T[], better: (a: T, b: T) => boolean): T {
	let best = xs[0];
	for (const x of xs) {
		if (better(x, best)) best = x;
	}
	return best;
}

function joined(parts: string[]): string {
	let out = "";
	for (let i = 0; i < parts.length; i += 1) {
		if (i > 0) out = out + ",";
		out = out + parts[i];
	}
	return out;
}

macro sortedAtCompileTime(v: Node): Node {
	const xs: number[] = [3, 1, 2];
	xs.sortBy((a: number, b: number): number => a - b);
	const shown: string[] = [];
	for (const x of xs) shown.push(x.toString());
	const ys: string[] = ["c", "a", "b"];
	ys.sortBy((a: string, b: string): number => a < b ? -1 : (a > b ? 1 : 0));
	return { kind: NodeKind.StringLiteral, line: v.line, column: v.column, value: joined(shown) + "|" + joined(ys) };
}

macro largestAtCompileTime(v: Node): Node {
	const top = largest<number>([4, 9, 2], (a: number, b: number): boolean => a > b);
	return { kind: NodeKind.StringLiteral, line: v.line, column: v.column, value: top.toString() };
}

console.log(`vm-generic ${sortedAtCompileTime(0)}|${largestAtCompileTime(0)}`);
