// @stdout: selected after 2 | captured 2
// @xfail(raiser): raiser-solid owns Raiser Promise APIs
// note: then reads its callback argument once, where the call is written: a call that returns the
// callback runs before the code after the then, and a variable names the callback it held then,
// not the one assigned to it before the promise settles.

let trace = "";

async function first(n: int32): Promise<int32> { return n + 1; }
async function second(n: int32): Promise<int32> { return n + 9; }

function select(): (n: int32) => Promise<int32> {
	trace += "selected ";
	return first;
}

async function run(): Promise<void> {
	const chosen = Promise.resolve(1 as int32).then(select());
	trace += "after ";
	let callback = first;
	const captured = Promise.resolve(1 as int32).then(callback);
	callback = second;
	const a = await chosen;
	const b = await captured;
	console.log(trace + a.toString() + " | captured " + b.toString());
}

await run();
