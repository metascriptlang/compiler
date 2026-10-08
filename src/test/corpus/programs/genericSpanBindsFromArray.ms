// @stdout: 7 5 8 7 7 5 5
// note: a generic `Span<T>` parameter binds `T` to the element of the sized array or Vec the argument converts from, also when the call sits in an `unknown` slot such as a `console.log` argument; before, that slot rebound `T` and the result printed as an unbound object.

struct Point { x: int32; y: int32; }

function firstOf<T>(storage: Span<T>): T {
	return storage[0];
}

function headOf<T>(this storage: Span<T>): T {
	return storage[0];
}

{
	let sized: uint8[4] = [7, 0, 0, 0];
	let vec: Vec<int32> = [5, 6];
	const shared: int32[] = [8, 9];
	const view: Span<uint8> = sized;
	let points: Vec<Point> = [{ x: 5, y: 1 }];
	console.log(firstOf(sized), firstOf(vec), firstOf(shared), firstOf(view), sized.headOf(), vec.headOf(), firstOf(points).x);
}
