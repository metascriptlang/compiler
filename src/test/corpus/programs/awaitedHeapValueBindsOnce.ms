// @stdout: s word-1 calls 1
// @stdout: a 3 x2 calls 2
// @stdout: b word-3 calls 3
// note: a value awaited outside an async function is bound once: the awaited call runs once and its string or array result is owned by the binding, at module top level and inside a block.

let calls: int32 = 0;

async function word(): Promise<string> {
	calls = calls + 1;
	return "word-" + calls.toString();
}

async function list(): Promise<string[]> {
	calls = calls + 1;
	return ["x" + calls.toString(), "y", "z"];
}

const s = await word();
console.log("s " + s + " calls " + calls.toString());
const a = await list();
console.log("a " + a.length.toString() + " " + a[0] + " calls " + calls.toString());
if (calls > 0) {
	const b = await word();
	console.log("b " + b + " calls " + calls.toString());
}
