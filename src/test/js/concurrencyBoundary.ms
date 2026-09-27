import { compileProjectToJSWithStd } from "../helpers";

struct ConcurrencyCase {
	name: string;
	source: string;
	accepted: boolean;
}

function accepts(source: string): boolean {
	const code = compileProjectToJSWithStd([{ entryPath: "test/concurrency.ms", entrySource: source }], "test/concurrency.ms");
	return !code.startsWith("ERROR:");
}

test "JavaScript spawn obeys borrowed and moved capture ownership" {
	const cases: ConcurrencyCase[] = [
		{ name: "mutable capture", source: "let x = 1; const h = spawn(() => x + 1); console.log(await h);", accepted: false },
		{ name: "borrowed write", source: "class Data { n: int32 = 0; } const d = new Data(); const h = spawn(() => { d.n = 5; return 0; }); await h;", accepted: false },
		{ name: "discarded handle", source: "spawn(() => 1);", accepted: false },
		{ name: "module owner move", source: "class Data { n: int32 = 7; } const d = new Data(); const h = spawn(() => d.n, { move: [d] }); console.log(await h);", accepted: false },
		{ name: "local owner move", source: "class Data { n: int32 = 7; } async function run(): Promise<int32> { const d = new Data(); const h = spawn(() => { d.n = d.n + 2; return d.n; }, { move: [d] }); return await h; } console.log(await run());", accepted: true },
		{ name: "immutable read", source: "const x = 1; const h = spawn(() => x + 1); console.log(await h);", accepted: true },
	];
	for (const c of cases) assert accepts(c.source) == c.accepted, c.name;
}

test "JavaScript awaits require a caller context that consumes asynchronous results" {
	const cases: ConcurrencyCase[] = [
		{ name: "synchronous function", source: "async function g(): Promise<int32> { return 1; } function run(): int32 { return await g(); } console.log(run());", accepted: false },
		{ name: "synchronous callback in async function", source: "async function g(n: int32): Promise<int32> { return n; } function each(xs: int32[], f: (n: int32) => void): void { for (const x of xs) f(x); } async function all(): Promise<void> { each([1, 2], (n: int32) => { console.log(await g(n)); }); } await all();", accepted: false },
		{ name: "module and async function", source: "async function g(): Promise<int32> { return 1; } async function run(): Promise<int32> { return await g(); } console.log(await run());", accepted: true },
		{ name: "spawn thunk", source: "async function g(): Promise<int32> { return 1; } const h = spawn(() => { return await g(); }); console.log(await h);", accepted: true },
	];
	for (const c of cases) assert accepts(c.source) == c.accepted, c.name;
}
