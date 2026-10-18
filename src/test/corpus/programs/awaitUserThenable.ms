// `await` of an object with a `then` resumes with what `then` delivers: synchronously, from a
// timer, through a generic class, a generic `then<R>`, an inherited method or a function field;
// an onRejected Error (or subclass) and a throwing `then` make the await throw it; only the
// first settlement counts.
// @stdout: now 5|later 6|caught nope|coded 9|box hi|generic 7|inherited|field 8|thrown bad|twice 1|empty|async 11
// @exit: 0

class Now {
	value: int32;
	constructor(v: int32) { this.value = v; }
	then(onFulfilled: (v: int32) => void): void { onFulfilled(this.value); }
}

async function deliverLater(onFulfilled: (v: int32) => void, v: int32): Promise<void> {
	await sleepAsync(5);
	onFulfilled(v);
}

class Later {
	then(onFulfilled: (v: int32) => void): void { deliverLater(onFulfilled, 6); }
}

class Refuse {
	then(onFulfilled: (v: int32) => void, onRejected: (reason: Error) => void): void { onRejected(new Error("nope")); }
}

class CodeError extends Error {
	code: int32;
	constructor(message: string, code: int32) {
		super(message);
		this.code = code;
	}
}

class RefuseCoded {
	then(onFulfilled: (v: int32) => void, onRejected?: (reason: CodeError) => void): void {
		if (onRejected != null) onRejected(new CodeError("coded", 9));
	}
}

class Box<T> {
	item: T;
	constructor(item: T) { this.item = item; }
	then(onFulfilled: (v: T) => void): void { onFulfilled(this.item); }
}

class Generic {
	then<R>(onFulfilled: (v: int32) => R, onRejected?: (reason: Error) => R): R {
		return onFulfilled(7);
	}
}

class Base {
	then(onFulfilled: (v: string) => void): void { onFulfilled("inherited"); }
}

class Derived extends Base {}

interface Deferred {
	then: (onFulfilled: (v: int32) => void) => void;
}

class Throws {
	then(onFulfilled: (v: int32) => void): void { throw new Error("bad"); }
}

class Twice {
	then(onFulfilled: (v: int32) => void, onRejected: (reason: Error) => void): void {
		onFulfilled(1);
		onFulfilled(2);
		onRejected(new Error("late"));
		throw new Error("ignored");
	}
}

class Empty {
	then(onFulfilled: () => void): void { onFulfilled(); }
}

async function makeNow(): Promise<int32> {
	return await new Now(11);
}

async function main(): Promise<void> {
	const out: string[] = [];
	out.push(`now ${await new Now(5)}`);
	out.push(`later ${await new Later()}`);
	try {
		await new Refuse();
		out.push("not thrown");
	} catch (e) {
		out.push(`caught ${e.message}`);
	}
	try {
		await new RefuseCoded();
	} catch (e) {
		out.push(e instanceof CodeError ? `coded ${(e as CodeError).code}` : "plain");
	}
	out.push(`box ${await new Box<string>("hi")}`);
	out.push(`generic ${await new Generic()}`);
	out.push(await new Derived());
	const d: Deferred = { then: (onFulfilled: (v: int32) => void): void => { onFulfilled(8); } };
	out.push(`field ${await d}`);
	try {
		await new Throws();
	} catch (e) {
		out.push(`thrown ${e.message}`);
	}
	out.push(`twice ${await new Twice()}`);
	await new Empty();
	out.push("empty");
	out.push(`async ${await makeNow()}`);
	console.log(out.join("|"));
}

main();
