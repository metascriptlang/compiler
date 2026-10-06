export class Root { tag: number = 1; speak(): string { return "..."; } }
export class Mid extends Root { m: number = 2; }
export class Leaf extends Mid { l: number = 3; speak(): string { return "gau"; } }

export function mkLeaf(): Leaf {
	return new Leaf();
}
