// @stdout: accounts:2:2
// @stdout: accounts:2:2
// @stdout: 7
// note: a module const of a struct of strings, a Vec and a Sendable function is unwritable through every path, so a spawn and an actor read it without Readonly, and the reads take no count on its cells.

struct Table { name: string; columns: Vec<string>; keyOf: Sendable<(id: uint32) => uint32>; }
function table(name: string, keyOf: Sendable<(id: uint32) => uint32>): Table {
	return { name: name, columns: ["id", "balance"], keyOf: keyOf };
}
export const accounts = table("accounts", (id: uint32): uint32 => id + 1);
function describe(): string {
	return accounts.name + ":" + String(accounts.columns.length) + ":" + String(accounts.keyOf(1));
}
function longest(): int32 {
	let n = 0;
	for (const c of accounts.columns) n = c.length > n ? c.length as int32 : n;
	return n + accounts.columns[0].length as int32 - 2;
}
actor Runner {
	source: Sendable<() => string>;
	constructor(source: Sendable<() => string>) { this.source = source; }
	run(): string { return this.source(); }
}
const runner = new Runner((): string => describe());
console.log(await runner.run());
const f = spawn(() => describe());
console.log(await f);
const g = spawn(() => longest());
console.log(String(await g));
