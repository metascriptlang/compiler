export class Counter {
	private count: int32 = 3;
	get value(): int32 { return this.count; }
	set value(v: int32) { this.count = v; }
}

export class Box<T> {
	constructor(private item: T) {}
	get inner(): T { return this.item; }
}
