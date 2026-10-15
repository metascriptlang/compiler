// @xfail(raiser): the Raiser VM cannot evaluate msGenericArrayPush, the rest accumulator (as in 905-destructuringAssignRest)
// @stdout: map a=1&b=2 | objects a=1&b=2 | rest 1:2 4:0 | defaults 1,2 4,9 | names 7
// note: a module pass that builds a new node for every top-level for-of, and a new array pattern inside it, from the fields it reads off the old one. The pattern, its rest element and its defaults must cross the compile-time VM's node conversion in both directions, so each loop still declares its names and fills an omitted element from its default. A for-of over a single name has no pattern and keeps its binding.

interface Pair { name: string; value: string; }

const search = new Map<string, string>();
search.set("a", "1");
search.set("b", "2");
const numbers: int32[][] = [[1, 2, 3], [4]];
const pairs: Pair[] = [{ name: "a", value: "1" }, { name: "b", value: "2" }];
const fromMap: string[] = [];
const fromObjects: string[] = [];
const rests: string[] = [];
const defaults: string[] = [];
let total = 0;

for (const [name, value] of search) fromMap.push(name + "=" + value);
for (const { name, value } of pairs) fromObjects.push(name + "=" + value);
for (const [first, ...rest] of numbers) rests.push(`${first}:${rest.length}`);
for (const [p, q = 9] of numbers) defaults.push(`${p},${q}`);
for (const row of numbers) total += row.length;
total += numbers.length + 1;

console.log(`map ${fromMap.join("&")} | objects ${fromObjects.join("&")} | rest ${rests.join(" ")} | defaults ${defaults.join(" ")} | names ${total}`);
