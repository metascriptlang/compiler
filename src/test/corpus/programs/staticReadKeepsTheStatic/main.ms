// @stdout: first ok ok | second ok ok | string hi hi | array 2 2 | locals hix 1 o | after hi 2 ok
// @stdout: module let ok ok | namespace 0.5 lib, 0.5 lib
// @stdout: ternary 0.5 static 0.25
// @xfail(raiser): the Raiser cannot read a static class field ('cannot evaluate 'A' at comptime: symbol kind is Class') (inbox 2026-10-09-raiser-cannot-read-a-static-class-field)
// @ledger-slack(msNumberArrayRefCell): 1
// note: a read of a class static, a module binding or a namespace member into an owned local or argument temp copies it; the static keeps its value for the next read. The slack is `A.L`, which outlives exit as module-level storage does.
import { Curves, Ease } from "./lib";
import * as lib from "./lib";

function view(): string { return "ok"; }
class A {
	static V: () => string = view;
	static S: string = "h" + "i";
	static L: number[] = [1, 2];
}
let moduleView: () => string = view;
function mk(): number { return 1; }
function first(comp: () => string, n: number): string { return comp(); }
function second(n: number, comp: () => string): string { return comp(); }
function str(s: string, n: number): string { return s; }
function arr(l: number[], n: number): number { return l.length; }
function ease(e: Ease, n: number): number { return e(0.5); }
function names(l: string[], n: number): string { return l[0]; }

function staticFirst(): string { return first(A.V, mk()); }
function staticSecond(): string { return second(mk(), A.V); }
function staticString(): string { return str(A.S, mk()); }
function staticArray(): number { return arr(A.L, mk()); }
function ownedLocals(): string {
	let s = A.S;
	s = s + "x";
	let l = A.L;
	l = [3];
	let c = A.V;
	const out = s + " " + l.length.toString() + " " + c().slice(0, 1);
	c = view;
	return out;
}
function moduleLet(): string { return first(moduleView, mk()); }
function viaNamespace(): string { return ease(lib.defaultEase, mk()).toString() + " " + names(lib.shared, mk()); }

class Holder {
	ease: Ease;
	constructor(e: Ease | null) {
		this.ease = e !== null ? e as Ease : Curves.linear;
	}
}

console.log(`first ${staticFirst()} ${staticFirst()} | second ${staticSecond()} ${staticSecond()} | string ${staticString()} ${staticString()} | array ${staticArray()} ${staticArray()} | locals ${ownedLocals()} | after ${A.S} ${A.L.length} ${A.V()}`);
console.log(`module let ${moduleLet()} ${moduleLet()} | namespace ${viaNamespace()}, ${viaNamespace()}`);
const h = new Holder(null);
console.log(`ternary ${h.ease(0.5)} static ${Curves.linear(0.25)}`);
