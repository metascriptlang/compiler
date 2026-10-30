// @stdout: unwrapped 7
// @stdout: void ok
// @stdout: void error: boom
// @stdout: box 3 void
// @stdout: box value 5

function must<T>(result: Result<T, string>): T {
	if (result.ok) { return result.value; }
	throw new Error(result.error);
}
function nothing(): Result<void, string> { return Result.ok(null); }
function failing(): Result<void, string> { return Result.err("boom"); }
function number(): Result<int32, string> { return Result.ok(7); }

struct Box<T> { v: T; n: int32; }
function unbox<T>(b: Box<T>): T { return b.v; }
function emptyBox(): Box<void> { return { v: null, n: 3 }; }
function fullBox(): Box<int32> { return { v: 5, n: 1 }; }

console.log("unwrapped " + String(must(number())));
must(nothing());
console.log("void ok");
try {
	must(failing());
} catch (e) {
	console.log("void error: " + (e as Error).message);
}
const empty = emptyBox();
unbox(empty);
console.log("box " + String(empty.n) + " void");
console.log("box value " + String(unbox(fullBox())));
