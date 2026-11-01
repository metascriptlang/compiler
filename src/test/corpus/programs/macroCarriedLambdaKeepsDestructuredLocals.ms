// @stdout: y 3 l r 9 c 7 ef
// note: a lambda handed to a macro and spliced back keeps the names its own destructuring declares (array, object, nested, rest, a destructured parameter) while a default that reads an outer local still reads that local. Same output on every backend.
import { Node } from "std/meta";

interface Pair { left: string; right: string }
interface Deep { pair: Pair; n: int32 }

function pair<T>(v: T): [() => T, (n: T) => void] {
	let cur = v;
	return [(): T => cur, (n: T): void => { cur = n; }];
}

macro keep(n: Node): Node { return n; }

function run(make: (n: int32) => string): string { return make(1); }
function pick(f: (p: Pair) => string): string { return f({ left: "l", right: "r" }); }

const outer = 9;
const flag = run(keep((n: int32): string => {
	const [get, set] = pair<boolean>(false);
	set(n > 0);
	return get() ? "y" : "n";
}));
const sum = run(keep((n: int32): string => {
	const t: [int32, int32] = [n, 2];
	const [a, b] = t;
	return String(a + b);
}));
const fields = pick(keep(({ left, right }: Pair): string => left + " " + right));
const defaulted = run(keep((n: int32): string => {
	const xs: int32[] = [];
	const [first = outer] = xs;
	return String(first);
}));
const nested = run(keep((n: int32): string => {
	const d: Deep = { pair: { left: "c", right: "d" }, n: 7 };
	const { pair: { left }, n: m } = d;
	return left + " " + String(m);
}));
const rest = run(keep((n: int32): string => {
	const p: Pair = { left: "e", right: "f" };
	const { left, ...others } = p;
	return left + others.right;
}));
console.log(flag, sum, fields, defaulted, nested, rest);
