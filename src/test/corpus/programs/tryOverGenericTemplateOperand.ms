// Parity program — a `try` whose operand is a call on a type parameter (`T.check(i)`) is untyped in
// the generic template and typed in each instance; the pass lowers the template without refusing it.
// Axes: a generic function, with and without a catch, and a method of a generic class, over two instances.
//
// @stdout: plain 6 -1
// @stdout: caught 5 -1
// @stdout: method 9 -1
// @exit: 0

struct Even { n: int32; }
struct Odd { n: int32; }

function check(this typeof Even, index: int32): Result<int32, string> {
	return index % 2 == 0 ? Result.ok(index) : Result.err("odd");
}

function check(this typeof Odd, index: int32): Result<int32, string> {
	return index % 2 == 1 ? Result.ok(index) : Result.err("even");
}

function plain<T>(index: int32): Result<int32, string> {
	const v = try T.check(index);
	return Result.ok(v + 1);
}

function caught<T>(index: int32): int32 {
	return try T.check(index) catch -1;
}

class Probe<T> {
	method(index: int32): Result<int32, string> {
		const v = try T.check(index);
		return Result.ok(v + 1);
	}
}

const a = plain<Odd>(5);
const b = plain<Even>(5);
console.log("plain", a.ok ? a.value : -1, b.ok ? b.value : -1);
console.log("caught", caught<Odd>(5), caught<Even>(5));
const even = new Probe<Even>().method(8);
const odd = new Probe<Odd>().method(8);
console.log("method", even.ok ? even.value : -1, odd.ok ? odd.value : -1);
