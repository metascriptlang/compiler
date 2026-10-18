export class Val {
	v: int32;
	constructor(v: int32) { this.v = v; }
	get(): int32 { return this.v; }
}
export class Box<T> {
	item: T;
	constructor(item: T) { this.item = item; }
	take(): T { return this.item; }
}
export class Base {
	label(): string { return "base"; }
}
export class Derived extends Base {
	n: int32 = 7;
}
