export class Box<T> {
	static hits: int32 = 0;
	static { Box.hits = 10; }
	v: T;
	constructor(v: T) { this.v = v; Box.hits += 1; }
	static count(): int32 { return 7; }
	static make(v: T): Box<T> { return new Box<T>(v); }
	size(): int32 { const s = @comptime { return sizeof(T); }; return s; }
}

export function sizeCode<T>(): int32 {
	const size = @comptime { return sizeof(T); };
	return size;
}
