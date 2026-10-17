// @stdout: declared 1|inferred 2|arrow 3|resolve 4|resolved later 5|handle 7|handle resolve 8|plain 4|caught nope|awaited in try 2
// @exit: 0
// note: every place a promise adopts a value adopts a thenable through the same `then` call: an async function's return (declared, inferred, arrow), `Promise.resolve`, and `await`. A `then` declared by an extension counts only when its receiver names the type: the generic `then<T>(this x: T)` in handleLib reaches neither `Plain` nor anything else, so an async function returns a `Plain` as itself. Inside a `try` with a catch, `return await` lets the catch see the rejection (a bare `return thenable` there is refused).

import { Handle, Plain } from "./handleLib";

const out: string[] = [];

class Now {
	v: int32;
	constructor(v: int32) { this.v = v; }
	then(onFulfilled: (v: int32) => void): void { onFulfilled(this.v); }
}

class Later {
	v: int32;
	constructor(v: int32) { this.v = v; }
	then(onFulfilled: (v: int32) => void): void { this.deliver(onFulfilled); }
	async deliver(onFulfilled: (v: int32) => void): Promise<void> {
		await sleepAsync(5);
		onFulfilled(this.v);
	}
}

class Refuse {
	then(onFulfilled: (v: int32) => void, onRejected: (reason: Error) => void): void { onRejected(new Error("nope")); }
}

async function declared(): Promise<int32> { return new Now(1); }
async function inferred() { return new Now(2); }
const arrow = async () => new Now(3);
async function refused(): Promise<int32> { return new Refuse(); }
async function givePlain(): Promise<Plain> { return new Plain(); }
async function awaitedInTry(): Promise<int32> {
	try {
		return await new Refuse();
	} catch (e) {
		return 2;
	}
}

async function main(): Promise<void> {
	out.push(`declared ${await declared()}`);
	out.push(`inferred ${await inferred()}`);
	out.push(`arrow ${await arrow()}`);
	out.push(`resolve ${await Promise.resolve(new Now(4))}`);
	out.push(`resolved later ${await Promise.resolve(new Later(5))}`);
	out.push(`handle ${await new Handle(7)}`);
	out.push(`handle resolve ${await Promise.resolve(new Handle(8))}`);
	const plain = await givePlain();
	out.push(`plain ${plain.n}`);
	try {
		await refused();
	} catch (e) {
		out.push(`caught ${e.message}`);
	}
	out.push(`awaited in try ${await awaitedInTry()}`);
	console.log(out.join("|"));
}

main();
