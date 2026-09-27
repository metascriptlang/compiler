class Node {
	name: string;
	constructor(n: string = "d") { this.name = n; }
}
class Base {
	s: string;
	constructor(s: string) { this.s = s; }
}
class Kid extends Base {
	constructor() { super("k"); }
}
export class Counter {
	static total: int32 = 100;
}
export function makeB(): string {
	Counter.total = Counter.total + 100;
	return new Node().name + new Kid().s + new Base("x").s + Counter.total.toString();
}
