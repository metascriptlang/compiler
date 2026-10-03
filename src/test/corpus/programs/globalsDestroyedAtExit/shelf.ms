export class Box {
	v: int32;
	constructor(v: int32) { this.v = v; }
}

const base: Box[] = [new Box(1), new Box(2)];
export const shared = base;
export const owned: Box[] = [new Box(3)];

export function boxes(n: int32): Box[] {
	const out: Box[] = [];
	for (let i = 0; i < n; i += 1) out.push(new Box(i));
	return out;
}
