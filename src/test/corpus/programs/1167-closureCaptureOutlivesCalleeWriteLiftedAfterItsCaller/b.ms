import { Wrapper, Box, hidden } from "./a";
class Pad { v: int32 = 99; }
function check(w: Wrapper): void {
	const item = w.items[0];
	const show = (): void => { console.log(item.v); };
	hidden(w);
	const pads: Pad[] = [];
	for (let i = 0; i < 64; i++) pads.push(new Pad());
	show();
}
export function run(): void {
	const w = new Wrapper();
	w.items.push(new Box());
	check(w);
}
