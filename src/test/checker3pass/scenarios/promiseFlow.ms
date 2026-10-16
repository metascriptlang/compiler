import { checkOnly } from "../helpers";

const DECLS = `
async function load(n: int32): Promise<int32> { return n; }
`;

test "new Promise<T> types its executor from T and is a Promise<T>" {
	const result = checkOnly(DECLS + `
struct Pair { n: int32; tag: string; }
const a: Promise<int32> = new Promise<int32>((resolve, reject) => { resolve(1); });
const b = new Promise<string>((resolve, reject) => { reject("e"); });
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
