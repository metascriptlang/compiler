// @stdout: b y sync a x g1 h1 t1 t2 g2 h2 t3
// @xfail(raiser): raiser-solid owns Raiser Promise APIs
// note: A callback runs after the synchronous code that registered it (even the first
// callback of the program, before any async function has run), and an await of an
// already finished promise resumes after it too, in the order the callbacks were queued.
// This is the order TypeScript gives and every backend must print: a .then callback comes
// after the statement that follows it (b a), an async function that awaited a finished
// promise continues after its caller's next statement (y x), two such functions
// interleave one await at a time (g1 h1 ... g2 h2), and a callback queued from inside a callback
// runs after the callbacks already queued (t1 t2 ... t3).

let out = "";

function note(s: string): void {
	out += (out == "" ? "" : " ") + s;
}

async function afterFinished(): Promise<void> {
	await Promise.resolve(0);
	note("x");
}

async function chain(tag: string): Promise<void> {
	await Promise.resolve(0);
	note(tag + "1");
	await Promise.resolve(0);
	note(tag + "2");
}

async function main(): Promise<void> {
	afterFinished();
	note("y");
	chain("g");
	chain("h");
	note("sync");
	Promise.resolve(0).then(() => {
		note("t1");
		Promise.resolve(0).then(() => note("t3"));
		note("t2");
	});
	await sleepAsync(20);
	console.log(out);
}

Promise.resolve(1).then(() => note("a"));
note("b");
await main();
