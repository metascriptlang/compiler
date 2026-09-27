// @xfail(raiser): the Raiser bytecode compiler drops a raise from inside a finally and hands the exception in flight to the inner catch, also on the baseline
// @stdout: inner swallowed|outer first|outer first|outer first|outer second|outer second|5|1|level2|caught level2 raise|outer in flight
// note: an exception in flight survives a finally that raises and handles another one; a raise or a jump out of the finally releases the exception it replaces (inject-scopes-2: C lost it and panicked, or leaked it).

function boom(m: string): void { throw new Error(m); }

function lexicalCatchInFinally(out: string[]): void {
	try {
		boom("first");
	} finally {
		try { boom("second"); } catch { out.push("inner swallowed"); }
	}
}

function cleanup(): void {
	try { boom("cleanup hiccup"); } catch { }
}

function helperCatchInFinally(): void {
	try {
		boom("first");
	} finally {
		cleanup();
	}
}

function deferCatches(): void {
	defer cleanup();
	boom("first");
}

function raiseInFinally(): void {
	try {
		boom("first");
	} finally {
		boom("second");
	}
}

function swallowByReturn(): int32 {
	try {
		boom("lost");
	} finally {
		return 5;
	}
	return 0;
}

function swallowByBreak(): int32 {
	let n: int32 = 0;
	while (n < 3) {
		n += 1;
		try {
			boom("lost in loop");
		} finally {
			break;
		}
	}
	return n;
}

function nestedFinallyRaise(out: string[]): void {
	try {
		boom("in flight");
	} finally {
		try {
			try { out.push("level2"); } finally { boom("level2 raise"); }
		} catch (e) {
			out.push(`caught ${e.message}`);
		}
	}
}

function run(): void {
	const out: string[] = [];
	try { lexicalCatchInFinally(out); } catch (e) { out.push(`outer ${e.message}`); }
	try { helperCatchInFinally(); } catch (e) { out.push(`outer ${e.message}`); }
	try { deferCatches(); } catch (e) { out.push(`outer ${e.message}`); }
	for (let i: int32 = 0; i < 2; i += 1) {
		try { raiseInFinally(); } catch (e) { out.push(`outer ${e.message}`); }
	}
	const r = swallowByReturn();
	out.push(r.toString());
	const b = swallowByBreak();
	out.push(b.toString());
	try { nestedFinallyRaise(out); } catch (e) { out.push(`outer ${e.message}`); }
	console.log(out.join("|"));
}
run();
