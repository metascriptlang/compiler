import { Inner } from "./sameNameHookInner";

export interface Item {
	s: Inner;
}

export function makeA(): number {
	const it: Item = { s: new Inner() };
	it.s.v = 1;
	return it.s.v;
}
