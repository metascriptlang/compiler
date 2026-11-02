// @stdout: 1 sync after the call
// @stdout: 2 after await 1
// note: an async function that awaits an async call which returned without suspending resumes after its caller's next statement, as in TypeScript.

async function ready(): Promise<int32> {
	return 1;
}

async function reader(): Promise<void> {
	const v = await ready();
	console.log("2 after await " + v.toString());
}

reader();
console.log("1 sync after the call");
