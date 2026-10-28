// @stdout: a|null|a 1 0
struct Item { name: string; mods: int32; }
let calls = 0;
function first(items: Readonly<Span<Item>>): Item | null {
	calls += 1;
	for (const b of items) { return b; }
	return null;
}
const items: Vec<Item> = [{ name: "a", mods: 1 }];
const none: Vec<Item> = [];
const shown = `${first(items)?.name}|${first(none)?.name}|${first(items)?.name}`;
console.log(`${shown} ${first(items)?.mods} ${calls - 4}`);
