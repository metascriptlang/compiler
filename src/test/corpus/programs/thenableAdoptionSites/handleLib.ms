export class Handle {
	id: int32;
	constructor(id: int32) { this.id = id; }
}

export function then(this h: Handle, onFulfilled: (v: int32) => void): void { onFulfilled(h.id); }

export class Plain {
	n: int32 = 4;
}

export function then<T>(this x: T, onFulfilled: (v: string) => void): void { onFulfilled("captured"); }
