struct Box {
	v: int32;
}

function pick<T>(this typeof Box, items: T[]): string {
	return "array";
}
function pick<A, B>(this typeof Box, items: [A, B]): string {
	return "pair";
}
function pick<A, B, C>(this typeof Box, items: [A, B, C]): string {
	return "triple";
}

function pick<T>(this typeof Iterator, items: T[]): string {
	return "iter-array";
}
function pick<A, B>(this typeof Iterator, items: [A, B]): string {
	return "iter-pair";
}

class Tag {}
function make<T>(this typeof Tag, items: T[]): int32 {
	return items.length as int32;
}
function make<A, B>(this typeof Tag, items: [A, B]): int32 {
	return 100;
}

test "static extension: two or three generic overloads of one name each emit the instance they pick" {
	const a: int32[] = [1, 2, 3];
	const p: [int32, string] = [1, "x"];
	const t: [int32, string, boolean] = [1, "x", true];
	assert Box.pick(a) == "array";
	assert Box.pick(p) == "pair";
	assert Box.pick(t) == "triple";
}

test "static extension: the same overload shapes on another receiver pick the same way" {
	const a: int32[] = [1, 2, 3];
	const p: [int32, string] = [1, "x"];
	assert Iterator.pick(a) == "iter-array";
	assert Iterator.pick(p) == "iter-pair";
	assert Tag.make(a) == 3;
	assert Tag.make(p) == 100;
}
