// Parity program — a `try` in an async function returns its error as the function's own
// Result, as it does in a sync function: the ok type of the tried value (Handle, void)
// differs from the function's (int64, string), with and without a pending defer, inside
// a loop, and after an await.
//
// @stdout: loop=7 Provider
// @stdout: sync=7 Provider async=7 Provider
// @stdout: deferred=7 Provider closed=2
// @stdout: void=done Work
// @exit: 0

class Handle {
	open: boolean = true;
	read: int64 = 7;
}

function close(this h: Handle): void {
	h.open = false;
}

enum FailureKind {
	Work,
	Provider,
}

struct Failure = match (kind: FailureKind) {
	FailureKind.Work => { detail: string },
	FailureKind.Provider => { step: string, code: int32 },
};

let closed = 0;

function opened(ok: boolean): Result<Handle, Failure> {
	if (!ok) { return Result.err({ kind: FailureKind.Provider, step: "open", code: 2 }); }
	return Result.ok(new Handle());
}

async function ready(failing: boolean): Promise<Result<void, Failure>> {
	await sleepAsync(1);
	if (failing) { return Result.err({ kind: FailureKind.Provider, step: "wait", code: 1020 }); }
	return Result.ok(null);
}

async function retry(): Promise<Result<void, Failure>> {
	return await ready(false);
}

async function readLoop(ok: boolean, failures: int32): Promise<Result<int64, Failure>> {
	const outer = try opened(ok);
	defer outer.close();
	let left = failures;
	while (true) {
		const step = try opened(true);
		defer step.close();
		const read = await ready(left > 0);
		if (read.ok) { return Result.ok(step.open ? step.read : -1); }
		if (read.error.kind != FailureKind.Provider) { return Result.err(read.error); }
		left -= 1;
		try await retry();
	}
}

function readSync(ok: boolean): Result<int64, Failure> {
	const h = try opened(ok);
	return Result.ok(h.read);
}

async function readAsync(ok: boolean): Promise<Result<int64, Failure>> {
	await sleepAsync(1);
	const h = try opened(ok);
	return Result.ok(h.read);
}

async function readDeferred(ok: boolean): Promise<Result<int64, Failure>> {
	defer { closed += 1; }
	await sleepAsync(1);
	const h = try opened(ok);
	return Result.ok(h.read);
}

async function work(fail: boolean): Promise<Result<void, Failure>> {
	await sleepAsync(1);
	if (fail) { return Result.err({ kind: FailureKind.Work, detail: "x" }); }
	return Result.ok(null);
}

async function label(fail: boolean): Promise<Result<string, Failure>> {
	defer { closed += 0; }
	try await work(fail);
	return Result.ok("done");
}

function show(r: Result<int64, Failure>): string {
	return r.ok ? r.value.toString() : r.error.kind.toString();
}

const good = await readLoop(true, 2);
const bad = await readLoop(false, 0);
console.log(`loop=${show(good)} ${show(bad)}`);
console.log(`sync=${show(readSync(true))} ${show(readSync(false))} async=${show(await readAsync(true))} ${show(await readAsync(false))}`);
const d1 = await readDeferred(true);
const d2 = await readDeferred(false);
console.log(`deferred=${show(d1)} ${show(d2)} closed=${closed}`);
const l1 = await label(false);
const l2 = await label(true);
console.log(`void=${l1.ok ? l1.value : "err"} ${l2.ok ? "ok" : l2.error.kind.toString()}`);
