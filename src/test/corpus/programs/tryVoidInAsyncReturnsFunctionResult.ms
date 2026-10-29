// @stdout: 42 false|err 1 false|big 3 false|err 2 true
import { sleepAsync } from "std/core/promise";

struct Failure {
	kind: int32;
	detail: string;
}

struct Big {
	a: int64;
	b: int64;
	c: int64;
}

class Handle {
	open: boolean = true;
	close(): void { this.open = false; }
}

function done(n: int32): Result<void, Failure> {
	if (n < 0) { return Result.err({ kind: -n, detail: "neg" }); }
	return Result.ok(null);
}

async function wait(n: int32): Promise<int32> {
	await sleepAsync(1);
	return n;
}

async function read(h: Handle, n: int32): Promise<Result<int32, Failure>> {
	defer h.close();
	const waited = try done(await wait(n));
	return Result.ok(42);
}

async function readBig(h: Handle, n: int32): Promise<Result<Big, Failure>> {
	try done(await wait(n));
	h.close();
	return Result.ok({ a: 1, b: 2, c: 3 });
}

async function main(): Promise<void> {
	const h1 = new Handle();
	const r1 = await read(h1, 40);
	const h2 = new Handle();
	const r2 = await read(h2, -1);
	const h3 = new Handle();
	const r3 = await readBig(h3, 1);
	const h4 = new Handle();
	const r4 = await readBig(h4, -2);
	const s1 = r1.ok ? `${r1.value}` : `err ${r1.error.kind}`;
	const s2 = r2.ok ? `${r2.value}` : `err ${r2.error.kind}`;
	const s3 = r3.ok ? `big ${r3.value.c}` : `err ${r3.error.kind}`;
	const s4 = r4.ok ? `big ${r4.value.c}` : `err ${r4.error.kind}`;
	console.log(`${s1} ${h1.open}|${s2} ${h2.open}|${s3} ${h3.open}|${s4} ${h4.open}`);
}
await main();
