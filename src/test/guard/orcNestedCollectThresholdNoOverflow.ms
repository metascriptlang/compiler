// nim-guard: a collection started from a destructor during a collection's free loop, where the
// threshold is held at its maximum, shrinks the threshold without signed overflow.
//
// Reference: an effective collection sets `rootsThreshold = max(rootsThreshold div 3 *% 2, 16)`
// (lib/system/orc.nim:495-496), dividing before it multiplies; the growth branch is skipped at
// or above `high(int) div 4` (orc.nim:499), so only the shrink branch can overflow.
// Built with signed-integer-overflow checks that abort, so the multiply-first order is red
// here: `drc.c: signed integer overflow: 2147483647 * 2`.
//
// RED MEANS msOrcCollect's shrink step multiplies before it divides; run /trace-ref on it
// against orc.nim collectCycles.

import { collectCycles } from "std/runtime";

@passC("-fsanitize=signed-integer-overflow -fno-sanitize-recover=all");
@passL("-fsanitize=signed-integer-overflow");

let destroyed = 0;
let depth = 0;
const keep: Node[] = [];
const liveP: Plain[] = [];

class Plain { next: Plain | null = null; }
class Node {
	next: Node | null = null;
	live: Node | null = null;
	onDestroy(): void {
		destroyed += 1;
		for (let i = 0; i < 300; i++) {
			const a = new Plain();
			const b = new Plain();
			a.next = b;
			b.next = a;
		}
		const l1 = new Plain();
		const l2 = new Plain();
		l1.next = l2;
		l2.next = l1;
		liveP.push(l1);
		if (destroyed % 50 === 0 && depth < nestingLimit) {
			depth += 1;
			collectCycles();
			depth -= 1;
		}
	}
}

let nestingLimit = 1;
const survivor = new Node();
survivor.next = survivor;
keep.push(survivor);

function ring(n: number): void {
	const first = new Node();
	let prev = first;
	for (let i = 0; i < n; i++) {
		const x = new Node();
		prev.next = x;
		x.live = survivor;
		prev = x;
	}
	prev.next = first;
}

function round(limit: int32): void {
	nestingLimit = limit;
	const before = destroyed;
	for (let k = 0; k < 20; k++) ring(100);
	collectCycles();
	collectCycles();
	if (destroyed - before < 2000) throw new Error(`nesting ${limit}: ${destroyed - before} destroyed, fewer than 2000`);
}

round(1);
round(3);
if (survivor.next !== survivor) throw new Error("the live cycle lost its edge");
console.log(`destroyed=${destroyed}`);
