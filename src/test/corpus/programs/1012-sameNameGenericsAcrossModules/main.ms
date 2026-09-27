// @stdout: main-box 7 lib-box lib-box|main-cell 8 lib-cell|main-pair 9 lib-pair|12 main-num
// note: one generic name declared in two modules, instantiated with the same type arguments on
// both sides. Each declaration keeps its own parameters, layout and C struct: the checker used to
// bind the other module's parameter names, and C used to emit one struct for both `Box<string>`.
import { libBox, libCell, libPair, readBox } from "./lib";

type Box<T> = { n: int32, w: T };
interface Cell<T> { n: int32; w: T; }
class Pair<T> { w: T; n: int32; constructor(w: T) { this.w = w; this.n = 9; } }

const box: Box<string> = { n: 7, w: "main-box" };
const cell: Cell<string> = { n: 8, w: "main-cell" };
const pair = new Pair<string>("main-pair");
const num: Box<number> = { n: 12, w: 1.5 };

console.log(`${box.w} ${box.n} ${libBox().v} ${readBox(libBox())}`);
console.log(`${cell.w} ${cell.n} ${libCell().v}`);
console.log(`${pair.w} ${pair.n} ${libPair().v}`);
console.log(`${num.n} main-num`);
