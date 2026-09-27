class Node {
	v: int32;
	constructor(v: int32 = 7) { this.v = v; }
}
class Base {
	n: int32;
	constructor(n: int32) { this.n = n; }
}
class Kid extends Base {
	constructor() { super(40); }
}
export class Counter {
	static total: int32 = 1;
	static label: string = "a";
}
export function makeA(): int32 {
	Counter.total = Counter.total + 1;
	return new Node().v + new Kid().n + new Base(1).n + Counter.total;
}
