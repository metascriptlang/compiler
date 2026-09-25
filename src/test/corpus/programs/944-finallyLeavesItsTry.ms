// @xfail(raiser): the Raiser bytecode compiler skips a finally left by `break` and one left by `return` inside a catch, also on the baseline
// @stdout: fin r|1|fin b|1|fin 0|fin 1|fin 2|33|fin|outer caught|calls=1|fin|caught|calls=1|loop fin|own caught|-1|calls=1|inner fin|outer catch|outer fin|2|calls=1
// note: a jump inside a finally does not run that finally again, and a raise from a finally inlined at a return or break leaves the try being left (inject-scopes-9 / -10: C ran the finally twice or caught the raise in the same try).

let calls: int32 = 0;
let out: string[] = [];

function flaky(): void {
	calls += 1;
	if (calls == 1) throw new Error("flaky");
}

function retInFinally(): int32 {
	try {
		calls += 0;
	} finally {
		out.push("fin r");
		return 1;
	}
	return 0;
}

function breakInFinally(): int32 {
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

function continueInFinally(): int32 {
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

function raiseAtReturnWithCatch(): int32 {
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

function raiseAtReturn(): int32 {
	try {
		return 7;
	} finally {
		out.push("fin");
		flaky();
	}
	return 0;
}

function raiseAtBreak(): int32 {
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

function raiseIntoOuterTry(): int32 {
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
	out.push(retInFinally().toString());
	out.push(breakInFinally().toString());
	out.push(continueInFinally().toString());
	try {
		const r = raiseAtReturnWithCatch();
		out.push(r.toString());
	} catch {
		out.push("outer caught");
	}
	out.push(`calls=${calls}`);
	calls = 0;
	try {
		const r = raiseAtReturn();
		out.push(r.toString());
	} catch {
		out.push("caught");
	}
	out.push(`calls=${calls}`);
	calls = 0;
	out.push(raiseAtBreak().toString());
	out.push(`calls=${calls}`);
	calls = 0;
	out.push(raiseIntoOuterTry().toString());
	out.push(`calls=${calls}`);
	console.log(out.join("|"));
}
run();
