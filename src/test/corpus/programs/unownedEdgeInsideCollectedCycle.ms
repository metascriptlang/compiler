// @skip-js: C-only by design: onDestroy counts the frees the cycle collector makes; JS frees nothing
// @stdout: ring 64 destroyed 64
// @stdout: holder destroyed 2, target destroyed 1
// note: Unowned<T> edges between members of one garbage cycle, and from a member to a target only that cycle holds, are given up while the collector destroys the cycle: every member and the target are destroyed once and freed after their last edge goes, in any order.
import { collectCycles } from "std/runtime";

class R {
	next: R | null = null;
	back: Unowned<R> | null = null;
	far: Unowned<R> | null = null;
}
let ringDestroyed = 0;
function onDestroy(this r: R): void { ringDestroyed++; }

function ring(n: int32): void {
	const first = new R();
	let last = first;
	for (let i = 1; i < n; i++) {
		const r = new R();
		r.back = last;
		r.far = first;
		last.next = r;
		last = r;
	}
	first.back = last;
	first.far = last;
	last.next = first;
}

class T { id: int32 = 5; }
let targetDestroyed = 0;
function onDestroy(this t: T): void { targetDestroyed++; }
class P {
	other: P | null = null;
	keep: T | null = null;
	see: Unowned<T> | null = null;
}
let holderDestroyed = 0;
function onDestroy(this p: P): void { holderDestroyed++; }

function pair(): void {
	const a = new P();
	const b = new P();
	const t = new T();
	a.other = b;
	b.other = a;
	b.keep = t;
	a.see = t;
}

ring(64);
collectCycles();
console.log("ring 64 destroyed " + ringDestroyed.toString());
pair();
collectCycles();
console.log("holder destroyed " + holderDestroyed.toString() + ", target destroyed " + targetDestroyed.toString());
