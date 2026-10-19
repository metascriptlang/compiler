import { checkOnly } from "../helpers";

const DECLS = `
async function load(n: int32): Promise<int32> { return n; }
`;

test "new Promise<T> types its executor from T and is a Promise<T>" {
	const result = checkOnly(DECLS + `
struct Pair { n: int32; tag: string; }
const a: Promise<int32> = new Promise<int32>((resolve, reject) => { resolve(1); });
const b = new Promise<string>((resolve, reject) => { reject(new Error("e")); });
const c = new Promise<Pair>((resolve, reject) => { resolve({ n: 1, tag: "t" }); });
const d = new Promise<void>((resolve, reject) => { resolve(); });
async function use(): Promise<int32> { return await a + (await c).n; }
`);
	assert result.errors.length == 0, "typed executors must check: " + result.errors.join("\n");
}

test "an executor that resolves another type than T, or a promise of a promise, is refused" {
	const wrong = checkOnly(DECLS + `
const a = new Promise<int32>((resolve, reject) => { resolve("text"); });
`).errors.join("\n");
	assert wrong.length > 0, "resolve(string) on a Promise<int32> must be refused";
	const nested = checkOnly(DECLS + `
const b = new Promise<Promise<int32>>((resolve, reject) => { });
`).errors.join("\n");
	assert nested.contains("is refused: its resolve would receive a promise"), "a promise of a promise must be refused: " + nested;
}

test "a returned promise inside try with a catch or finally is refused with the rewrite" {
	const errors = checkOnly(DECLS + `
async function inCatch(n: int32): Promise<int32> {
	try { return load(n); } catch (e) { return -1; }
}
async function inFinally(n: int32): Promise<int32> {
	try { return load(n); } finally { load(0); }
}
async function inCatchWithFinally(n: int32): Promise<int32> {
	try { throw new Error("x"); } catch (e) { return load(n); } finally { load(0); }
}
`).errors;
	const text = errors.join("\n");
	assert text.contains("a returned promise is not awaited inside try — write `return await …` so catch and finally see its result"), "return load(n) in try must be refused: " + text;
	assert errors.length == 3, "catch, finally and catch-with-finally are three refusals: " + text;
}

test "a returned promise outside try is awaited: functions, arrows, a rejection and a resolved value" {
	const result = checkOnly(DECLS + `
async function viaFn(n: int32): Promise<int32> { return load(n); }
async function guarded(n: int32): Promise<int32> {
	try { return await load(n); } catch (e) { return -1; } finally { load(0); }
}
async function afterTry(n: int32): Promise<int32> {
	try { await load(n); } catch (e) { }
	return load(n);
}
async function nestedFn(n: int32): Promise<int32> {
	try {
		const inner = async (): Promise<int32> => { return load(n); };
		return await inner();
	} catch (e) { return -1; }
}
const arrow = async (n: int32): Promise<int32> => { return load(n); };
const expr = async (n: int32) => load(n);
async function rejected(): Promise<int32> { return Promise.reject(new Error("e")); }
async function resolved(): Promise<int32> { return Promise.resolve(7); }
`);
	assert result.errors.length == 0, "valid promise flow must check: " + result.errors.join("\n");
}
