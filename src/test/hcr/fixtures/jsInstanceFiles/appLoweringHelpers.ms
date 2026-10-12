import { wrap, count, same, tagged, Mode, Box, ownBox, summary } from "./lib";

struct Point {
	x: int32;
	y: int32;
}

const held: unknown = new Box<int32>(7);
const shared = ownBox() as Box<string>;
console.log(`JS-INST first ${wrap(1).length} ${(held as Box<int32>).get()} ${shared.get()} ${count(2)} ${summary()}`);
const flag: unknown = new Box<boolean>(true);
const text = new Box<string>("app");
console.log(`JS-INST second ${wrap(true).length} ${(flag as Box<boolean>).get()} ${text.get()} ${count(3)} ${summary()}`);
const p: Point = { x: 1, y: 2 };
const q: Point = { x: 1, y: 2 };
const r: Point = { x: 1, y: 3 };
console.log(`JS-INST fourth ${same(p, q)} ${same(p, r)} ${tagged(1, Mode.On)}`);
