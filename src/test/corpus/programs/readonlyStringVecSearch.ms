// @stdout: true false 1 -1
// @stdout: true 2
struct Hub { tables: Vec<string>; }
struct Outer { hub: Hub; }
function search(hub: Readonly<Hub>, name: string): string {
	return `${hub.tables.includes(name)}`;
}
function find(outer: Readonly<Outer>, name: string): int32 {
	return outer.hub.tables.indexOf(name) as int32;
}
const hub: Hub = { tables: ["a", "b", "c"] };
const outer: Outer = { hub: hub };
console.log(`${search(hub, "b")} ${search(hub, "z")} ${find(outer, "b")} ${find(outer, "z")}`);
console.log(`${search(hub, "c")} ${find(outer, "c")}`);
