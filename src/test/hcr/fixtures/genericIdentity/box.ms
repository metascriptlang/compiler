export class Plain {
	n: int32;
	constructor(n: int32) { this.n = n; }
}

export class Box<T> {
	v: T;
	constructor(v: T) { this.v = v; }
}
