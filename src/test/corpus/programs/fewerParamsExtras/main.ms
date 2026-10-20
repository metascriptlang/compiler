// @stdout: extras q5 q- qq! w- q? i?
// @stdout: identity true true false true
// A function value with more parameters than the slot it fills, every extra one optional:
// the adapter passes the slot's arguments and fills the rest with the default the
// declaration names (read in its own module) or with the absent value, and `===` still
// sees the function itself.
import { tag } from "./lib";

function g(a: string, b: int32 = 5): string { return a + b; }
function o(a: string, b?: string): string { return a + (b ?? "-"); }
function echo(a: string, c: string = a + "!"): string { return a + c; }
function apply(f: (s: string) => string): string { return f("q"); }
interface Box { run: ((s: string) => string) | null; }

let last: ((s: string) => string) | null = null;
function keep(f: (s: string) => string): void { last = f; }

function main(): void {
	const box: Box = { run: o };
	const arrow = (a: string, b?: string): string => a + (b ?? "?");
	const viaBox = box.run != null ? box.run("w") : "";
	const imported: (s: string) => string = tag;
	console.log(`extras ${apply(g)} ${apply(o)} ${apply(echo)} ${viaBox} ${apply(arrow)} ${imported("i")}`);
	keep(g);
	const first = last;
	keep(g);
	const named: (s: string) => string = g;
	const other: (s: string) => string = o;
	console.log(`identity ${first === last} ${last === named} ${last === other} ${last !== other}`);
}

main();
