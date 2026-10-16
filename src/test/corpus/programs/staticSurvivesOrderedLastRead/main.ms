// The last read of a class static or a namespace member, taken before a raising call later in
// the same argument list, copies the value: the static still holds it on the next call.
// @stdout: v1 3 w1 s1|v2 3 w2 s2|done
import * as lib from "./lib";

function plain(n: number): string { return "v" + n.toString(); }
class K {
	static V: (n: number) => string = plain;
	static A: string[] = ["a", "b"];
	static S: string = "s";
}
interface Box { n: number; }
function mayThrow(n: number): number {
	if (n < 0) throw new Error("negative");
	return n;
}
function apply(f: (n: number) => string, b: Box): string { return f(b.n); }
function count(xs: string[], b: Box): number { return xs.length + b.n; }
function tag(s: string, b: Box): string { return s + b.n.toString(); }

function once(n: number): string {
	const v = apply(K.V, { n: mayThrow(n) });
	const c = count(K.A, { n: mayThrow(n) });
	const w = apply(lib.V, { n: mayThrow(n) }).replace("v", "w");
	return `${v} ${c - n + 1} ${w} ${tag(K.S, { n: mayThrow(n) })}`;
}
console.log(`${once(1)}|${once(2)}|done`);
