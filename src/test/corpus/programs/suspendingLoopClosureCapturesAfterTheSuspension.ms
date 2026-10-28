// @stdout: next 0 t0 1 t1
// @stdout: while 0 w0 1 w1
// @stdout: pair 0 p0:p0 1 p1:p1
// @stdout: finally v0 f0! v1 f1!
// @stdout: async a0 a1
// note: a binding declared after a yield or an await inside a loop, then captured by a closure, holds that iteration's value when the closure runs. Before the fix C built the closure's environment at the top of the resume step, ahead of the declaration, so a closure made in a `case` of the state machine read the previous iteration's value or an empty one.

function* tagsByFor(): Iterator<string> {
	for (let i: int32 = 0; i < 2; i++) {
		yield String(i);
		const tag = `t${i}`;
		const f = (): string => tag;
		yield f();
	}
}

function* tagsByWhile(): Iterator<string> {
	let i: int32 = 0;
	while (i < 2) {
		yield String(i);
		const tag = `w${i}`;
		const f = (): string => tag;
		i++;
		yield f();
	}
}

function* tagsByPair(): Iterator<string> {
	for (let i: int32 = 0; i < 2; i++) {
		yield String(i);
		const tag = `p${i}`;
		const f = (): string => tag;
		const g = (): string => tag;
		yield f() + ":" + g();
	}
}

function* tagsInFinally(): Iterator<string> {
	for (let i: int32 = 0; i < 2; i++) {
		try {
			yield "v" + String(i);
		} finally {
			const tag = "f" + String(i);
			const f = (): string => tag + "!";
			yield f();
		}
	}
}

function drain(g: Iterator<string>): string {
	let out = "";
	let r = g.next();
	while (!r.done) {
		out = out + " " + r.value;
		r = g.next();
	}
	return out;
}

async function tagsAsync(): Promise<string> {
	let out = "";
	for (let i: int32 = 0; i < 2; i++) {
		await Promise.resolve(0);
		const tag = `a${i}`;
		const f = (): string => tag;
		out = out + " " + f();
	}
	return out;
}

console.log("next" + drain(tagsByFor()));
console.log("while" + drain(tagsByWhile()));
console.log("pair" + drain(tagsByPair()));
console.log("finally" + drain(tagsInFinally()));
console.log("async" + await tagsAsync());
