// @stdout: async-generic ok 7
// note: an async routine inside generic code runs on every backend: a generic `async function` returning its `T` (explicit and inferred `T`, a number and a string), an `async` method of a generic class, a generic function taking an async callback whose `T` is inferred through `Promise<T>`, and an async function declared inside a generic function that awaits a `Promise<Result<T, string>>` built from the outer `T`. The `return` of each is checked against the awaited `T`, and the nested async function is lowered only in each instance of its generic parent. Same output on C, JS and the Raiser.
import { sleepAsync } from "std/core/promise";

let wrong = "";
let rows = 0;
function row(name: string, got: string, want: string): void {
	rows += 1;
	if (got != want) wrong += " " + name + "=" + got + "(want " + want + ")";
}

async function generic<T>(v: T): Promise<T> {
	await sleepAsync(1);
	return v;
}

class Slot<T> {
	value: T;
	constructor(value: T) { this.value = value; }
	async wait(): Promise<T> {
		await sleepAsync(1);
		return this.value;
	}
}

async function call<T>(fn: (n: number) => Promise<T>): Promise<T> { return await fn(2); }

async function one(): Promise<Result<int32, string>> {
	await sleepAsync(1);
	return Result.ok(7);
}

async function word(): Promise<Result<string, string>> {
	await sleepAsync(1);
	return Result.ok("w");
}

let settled = "";
function start<T>(fetch: () => Promise<Result<T, string>>, done: (v: T) => void): void {
	async function settle(request: Promise<Result<T, string>>): Promise<void> {
		const result = await request;
		if (result.ok) { done(result.value); }
	}
	settle(fetch());
}

async function main(): Promise<void> {
	row("explicit", (await generic<int32>(2)).toString(), "2");
	row("inferred", await generic("x"), "x");
	row("method number", (await new Slot<int32>(3).wait()).toString(), "3");
	row("method string", await new Slot<string>("s").wait(), "s");
	row("callback", await call(async (n: number): Promise<string> => { return "a" + n.toString(); }), "a2");
	start(one, (v: int32): void => { settled += "got:" + v.toString(); });
	start(word, (v: string): void => { settled += "got:" + v; });
	await sleepAsync(5);
	row("nested", settled, "got:7got:w");
	row("rows", rows.toString(), "6");
	console.log(wrong == "" ? "async-generic ok " + rows.toString() : "async-generic WRONG" + wrong);
}
main();
