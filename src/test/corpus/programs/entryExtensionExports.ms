class Handle {
	value: int32;
	constructor(value: int32) { this.value = value; }
}

export function then(
	this handle: Handle,
	onFulfilled: (value: int32) => void,
): void {
	onFulfilled(handle.value);
}

export function increment(value: int32): int32 {
	return value + 1;
}

const first = await new Handle(7);
const second = await new Handle(9);
const result = `${first} ${second} ${increment(4)}`;
if (result != "7 9 5") {
	throw new Error("entry extension export lost its callable identity");
}
console.log(result);
