interface Item { a: int32; b: int32; }

class Tag {
	n: int32 = 0;
}

export function wrap<T>(x: T): T[] {
	const out: T[] = [];
	out.push(x);
	return out;
}

export function libSum(): int32 {
	const i: Item = { a: 1 as int32, b: 2 as int32 };
	const t = new Tag();
	t.n = 4 as int32;
	return i.a + i.b + t.n;
}
