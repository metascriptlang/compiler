// @stdout: message=refused|generic=refused|record=refused|resolved=fine
// @exit: 0
// @xfail(raiser): an async call runs inline on the Raiser, so the rejection escapes as an unhandled exception before the waiter awaits it (card 2026-10-15-raiser-async-call-runs-inline)
// note: an async function awaiting a promise it received as a parameter catches a rejection that happens after a suspension: a string payload, the same through a generic watcher, a struct payload holding a string, and a string promise that resolves as the control.

import { sleepAsync } from "std/core/promise";

struct Record {
	name: string;
	n: int32;
}

async function failText(): Promise<string> {
	await sleepAsync(1);
	throw new Error("refused");
}

async function failRecord(): Promise<Record> {
	await sleepAsync(1);
	throw new Error("refused");
}

async function fine(): Promise<string> {
	await sleepAsync(1);
	return "fine";
}

const seen: string[] = [];

async function waiter(label: string, promise: Promise<string>): Promise<void> {
	let message = "none";
	try {
		const value = await promise;
		message = value;
	} catch (e) {
		message = e.message;
	}
	seen.push(label + "=" + message);
}

async function watch<T>(label: string, promise: Promise<T>): Promise<void> {
	let message = "none";
	try {
		await promise;
		message = "resolved";
	} catch (e) {
		message = e.message;
	}
	seen.push(label + "=" + message);
}

async function main(): Promise<void> {
	await waiter("message", failText());
	await watch<string>("generic", failText());
	await watch<Record>("record", failRecord());
	await waiter("resolved", fine());
	console.log(seen.join("|"));
}

await main();
