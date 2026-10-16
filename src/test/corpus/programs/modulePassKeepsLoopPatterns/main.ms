// @xfail(raiser): the Raiser VM cannot evaluate msGenericArrayPush, the rest accumulator (as in 905-destructuringAssignRest)
// @stdout: map a=1&b=2 | pairs a=1&b=2 | objects a=1&b=2 | nested x12 y34 y56 | rest 1:2 4:0 | defaults 1,2 4,9 | decl 1 5
// note: a module pass receives every module and returns it through the compile-time VM's node conversion. Here the pass returns the module untouched, so a for-of whose binding is a pattern must come back with that pattern: over a Map, over array pairs, over objects, a pattern loop nested in a pattern loop, a rest element, and a default; a plain destructuring declaration keeps its default too. A lost pattern shows as an undefined name, a lost default as an index out of bounds at run time.

interface Pair { name: string; value: string; }
interface Cell { a: int32; b: int32; }

const search = new Map<string, string>();
search.set("a", "1");
search.set("b", "2");
const fromMap: string[] = [];
for (const [name, value] of search) fromMap.push(name + "=" + value);

const rows: string[][] = [["a", "1"], ["b", "2"]];
const fromPairs: string[] = [];
for (const [name, value] of rows) fromPairs.push(name + "=" + value);

const pairs: Pair[] = [{ name: "a", value: "1" }, { name: "b", value: "2" }];
const fromObjects: string[] = [];
for (const { name, value } of pairs) fromObjects.push(name + "=" + value);

const grid = new Map<string, Cell[]>();
grid.set("x", [{ a: 1, b: 2 }]);
grid.set("y", [{ a: 3, b: 4 }, { a: 5, b: 6 }]);
const nested: string[] = [];
for (const [k, row] of grid) {
	for (const { a, b } of row) nested.push(`${k}${a}${b}`);
}

const numbers: int32[][] = [[1, 2, 3], [4]];
const rests: string[] = [];
for (const [first, ...rest] of numbers) rests.push(`${first}:${rest.length}`);
const defaults: string[] = [];
for (const [p, q = 9] of numbers) defaults.push(`${p},${q}`);

const one: int32[] = [1];
const [c, d = 5] = one;

console.log(`map ${fromMap.join("&")} | pairs ${fromPairs.join("&")} | objects ${fromObjects.join("&")} | nested ${nested.join(" ")} | rest ${rests.join(" ")} | defaults ${defaults.join(" ")} | decl ${c} ${d}`);
