export class Source__MMarker {
	static name: string = "author";
	value: int32;
	constructor(value: int32) { this.value = value; }
}

export class Box<T> {
	value: T;
	constructor(value: T) { this.value = value; }
}

export function source(): unknown { return new Source__MMarker(9); }
export function boxed(): unknown { return new Box<int32>(7); }
