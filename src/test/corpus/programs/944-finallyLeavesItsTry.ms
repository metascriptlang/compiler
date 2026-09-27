// @xfail(raiser): the Raiser bytecode compiler skips a finally left by `break` and one left by `return` inside a catch, also on the baseline
// @stdout: fin r|1|fin b|1|fin 0|fin 1|fin 2|33|fin|outer caught|calls=1|fin|caught|calls=1|loop fin|own caught|-1|calls=1|inner fin|outer catch|outer fin|2|calls=1
// note: a jump inside a finally does not run that finally again, and a raise from a finally inlined at a return or break leaves the try being left (inject-scopes-9 / -10: C ran the finally twice or caught the raise in the same try).

let calls: int32 = 0;

function flaky(): void {
	calls += 1;
	if (calls == 1) throw new Error("flaky");
}

function retInFinally(out: string[]): int32 {
	try {
		calls += 0;
	} finally {
		out.push("fin r");
		return 1;
	}
	return 0;
}

function breakInFinally(out: string[]): int32 {
	let n: int32 = 0;
	while (n < 5) {
		n += 1;
		try {
			calls += 0;
		} finally {
			out.push("fin b");
			break;
		}
	}
	return n;
}

function continueInFinally(out: string[]): int32 {
	let n: int32 = 0;
	let fins: int32 = 0;
	for (let i: int32 = 0; i < 3; i += 1) {
		try {
			n += 1;
		} finally {
			fins += 1;
			out.push(`fin ${i}`);
			continue;
		}
	}
	return n * 10 + fins;
}

function raiseAtReturnWithCatch(out: string[]): int32 {
	try {
		return 7;
	} catch {
		out.push("own catch");
		return 8;
	} finally {
		out.push("fin");
		flaky();
	}
	return 0;
}

function raiseAtReturn(out: string[]): int32 {
	try {
		return 7;
	} finally {
		out.push("fin");
		flaky();
	}
	return 0;
}

function raiseAtBreak(out: string[]): int32 {
	let n: int32 = 0;
	try {
		while (n < 3) {
			n += 1;
			try {
				break;
			} finally {
				out.push("loop fin");
				flaky();
			}
		}
		out.push("after loop");
	} catch {
		out.push("own caught");
		return -1;
	}
	return n;
}

function raiseIntoOuterTry(out: string[]): int32 {
	try {
		try {
			return 1;
		} finally {
			out.push("inner fin");
			flaky();
		}
	} catch {
		out.push("outer catch");
		return 2;
	} finally {
		out.push("outer fin");
	}
	return 0;
}

function run(): void {
	const out: string[] = [];
	out.push(retInFinally(out).toString());
	out.push(breakInFinally(out).toString());
	out.push(continueInFinally(out).toString());
	try {
		const r = raiseAtReturnWithCatch(out);
		out.push(r.toString());
	} catch {
		out.push("outer caught");
	}
	out.push(`calls=${calls}`);
	calls = 0;
	try {
		const r = raiseAtReturn(out);
		out.push(r.toString());
	} catch {
		out.push("caught");
	}
	out.push(`calls=${calls}`);
	calls = 0;
	out.push(raiseAtBreak(out).toString());
	out.push(`calls=${calls}`);
	calls = 0;
	out.push(raiseIntoOuterTry(out).toString());
	out.push(`calls=${calls}`);
	console.log(out.join("|"));
}
run();
