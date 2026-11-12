import { Leaf, viaKeep } from "./b";

export class P { name: string; constructor(name: string) { this.name = name; } }

export class Tree {
	leaf: Leaf;
	constructor(p: P) { this.leaf = new Leaf(p); }
}

export class Hold {
	item: P;
	constructor(item: P) { this.item = item; }
}

export function viaTree(): string {
	const p = new P("t");
	const t = new Tree(p);
	return t.leaf.up!.name;
}

export function both(): string { return viaTree() + viaKeep(); }
