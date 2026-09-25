// nim-guard: cyclic elements dropped by a runtime ref-array op are collected
//
// INVARIANT (liftdestructors.nim fillSeqOp -> forallElements -> atomicRefOp: a seq of a
//   cyclic element type decrefs each element with nimDecRefIsLastCyclic*, whose
//   rememberCycle registers a surviving element as a root): a self-cycle whose last
//   external ref leaves through an array destroy or splice is reclaimed under orc.
// NIM-REF AN-19 (SAME). Leaks under drc by design (ARC does not collect cycles).
//
// RED MEANS: a runtime element op decrefs with plain msDecref again.
//   Run /trace-nim on msRefArrayDestroy / msRefArraySplice3 (runtime/core/array.c).
// GUARD-BALANCE-ORC Node

class Node {
	next: Node | null = null;
	id: int32 = 0;
}

function make(i: int32): Node {
	const n = new Node();
	n.id = i;
	n.next = n;
	return n;
}

function arrayDestroy(): int32 {
	let total: int32 = 0;
	for (let i: int32 = 0; i < 300; i++) {
		const arr: Node[] = [];
		arr.push(make(i));
		total = total + arr[0].id;
	}
	return total;
}

function spliceInsert(): int32 {
	const arr: Node[] = [make(0)];
	for (let i: int32 = 1; i < 300; i++) {
		arr.splice(0, 1, make(i));
	}
	return arr[0].id;
}

function vecDestroy(): int32 {
	let total: int32 = 0;
	for (let i: int32 = 0; i < 300; i++) {
		const v: Vec<Node> = [];
		v.push(make(i));
		total = total + v[0].id;
	}
	return total;
}

console.log(arrayDestroy(), spliceInsert(), vecDestroy());
console.log("GUARD-OK");
