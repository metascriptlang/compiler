import { run } from "./b";
export class Box { v: int32 = 7; }
export class Wrapper { items: Box[] = []; }
class Pad { v: int32 = 99; }
export function dropFirst(w: Wrapper): void { w.items.pop(); }
export function process(x: Box, w: Wrapper): void {
	dropFirst(w);
	const pads: Pad[] = [];
	for (let i = 0; i < 64; i++) pads.push(new Pad());
	console.log(x.v);
}
export function again(): void { run(); }
