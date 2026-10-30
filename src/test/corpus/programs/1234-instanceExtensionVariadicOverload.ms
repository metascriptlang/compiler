// @stdout: 3 600 900 0 0
// @stdout: -2 3 2 0
class Box {}
class Cell<T> { value: T; }

function top(this b: Box, a: int32, c: int32): int32 { return a + c; }
function top(this b: Box, ...xs: int32[]): int32 {
	let s: int32 = 0;
	for (const x of xs) s += x;
	return s * 100;
}

function count<T>(this c: Cell<T>, a: int32, b: int32): int32 { return -2; }
function count<T>(this c: Cell<T>, ...xs: int32[]): int32 { return xs.length; }

const box = new Box();
const xs: int32[] = [4, 5];
const none: int32[] = [];
console.log(box.top(1, 2), box.top(1, 2, 3), box.top(...xs), box.top(...none), box.top());
const cell = new Cell<string>();
console.log(cell.count(1, 2), cell.count(1, 2, 3), cell.count(...xs), cell.count(...none));
