export struct Box<T> {
	v: T;
	pad: int8;
}

export function padOf(b: Box<int32>): string {
	return `${b.v}/${b.pad}`;
}
