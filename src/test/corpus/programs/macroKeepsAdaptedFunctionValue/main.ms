// @stdout: hits=4 pair=7:x
// note: a function value passed to a slot taking more parameters keeps its value through a macro that hands its argument back.
import { same } from "./keep";

function call1(h: (e: int32) => void): void { h(7); }
function call2(h: (n: int32, s: string) => void): void { h(7, "x"); }
let hits = 0;
let pair = "";

function throughArrow(pressed: () => void): void {
	const f = same((x: int32): void => { call1(pressed); });
	f(1);
}
function asArgument(pressed: () => void): void {
	same(call1(pressed));
}
function twoSlot(seen: (n: int32) => void): void {
	same(call2(seen));
}

throughArrow((): void => { hits += 1; });
asArgument((): void => { hits += 1; });
same(call1((): void => { hits += 1; }));
same(call2((n: int32): void => { hits += 1; pair = n.toString() + ":x"; }));
twoSlot((n: int32): void => { pair = n.toString() + ":x"; });
console.log(`hits=${hits} pair=${pair}`);
