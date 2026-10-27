import { run } from "./b";
export class Box { v: int32 = 7; }
export class Wrapper { items: Box[] = []; }
class Pad { v: int32 = 99; }
export function hidden(w: Wrapper): void { w.items.pop(); }
function selfCheck(w: Wrapper): void {
	const item = w.items[0];
	hidden(w);
	const pads: Pad[] = [];
	for (let i = 0; i < 64; i++) pads.push(new Pad());
	console.log("a:" + item.v);
}
export function again(): void {
	run();
	const w = new Wrapper();
	w.items.push(new Box());
	selfCheck(w);
}
