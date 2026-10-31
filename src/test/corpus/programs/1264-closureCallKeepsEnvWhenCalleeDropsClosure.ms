// @stdout: 7
// @stdout: 8
// @stdout: 9
// @stdout: hello5
// note: a closure called through a module variable, a field or an array slot while the call clears or replaces that slot keeps its env alive until the call returns; a string capture reads back whole.
class Box { v: int32 = 7; }
class Holder { f: (() => int32) | null = null; }
function poke(b: Box, cb: () => void): int32 { cb(); return b.v; }
function pokeText(s: string, cb: () => void): string { cb(); return s; }

let moduleSlot: (() => int32) | null = null;
function viaModule(): void {
	const box = new Box();
	moduleSlot = () => poke(box, () => { moduleSlot = null; });
}

const holder = new Holder();
function viaField(): void {
	const box = new Box();
	box.v = 8;
	holder.f = () => poke(box, () => { holder.f = null; });
}

const slots: (() => int32)[] = [];
function viaElement(): void {
	const box = new Box();
	box.v = 9;
	slots.push(() => poke(box, () => { slots[0] = () => 0; }));
}

let textSlot: (() => string) | null = null;
function viaString(): void {
	const s = "hel" + "lo" + (2 + 3);
	textSlot = () => pokeText(s, () => { textSlot = null; });
}

viaModule();
console.log(moduleSlot!());
viaField();
console.log(holder.f!());
viaElement();
console.log(slots[0]());
viaString();
console.log(textSlot!());
