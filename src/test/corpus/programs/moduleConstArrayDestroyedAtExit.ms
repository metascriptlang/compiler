// @stdout: 33 2 i1 s2t2 r1

class Item {
	name: string;
	constructor(n: string) { this.name = n; }
}
struct Slot { item: Item; tag: string; }

function counter(start: int32): () => int32 {
	let n = start;
	return (): int32 => {
		n += 1;
		return n;
	};
}

const handlers: (() => int32)[] = [];
export const items: Item[] = [];
const slots: Slot[] = [];
const rows: Item[][] = [];

for (let i = 0; i < 3; i += 1) {
	handlers.push(counter(i * 10));
	items.push(new Item("i" + i.toString()));
	slots.push({ item: new Item("s" + i.toString()), tag: "t" + i.toString() });
}
rows.push([new Item("r0"), new Item("r1")]);
items.pop();

let sum = 0;
for (const h of handlers) sum += h();
console.log(`${sum} ${items.length} ${items[1].name} ${slots[2].item.name}${slots[2].tag} ${rows[0][1].name}`);
