import { Inner } from "./sameNameHookInner";

// Deliberately the same type name as sameNameHookA's `Item`, declared by a
// different module — the collision the guard exists for.
export interface Item {
	s: Inner;
}

export function makeB(): number {
	const it: Item = { s: new Inner() };
	it.s.v = 2;
	return it.s.v;
}
