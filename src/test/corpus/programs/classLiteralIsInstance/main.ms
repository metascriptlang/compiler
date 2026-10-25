// @stdout: own 4 4 true | virtual 5 5 6 true true | spread 9 27 | imported 12 true | plain 4 2 true | generic box 7
import { Cell } from "./cell";
class Counter { v: int32; constructor(v: int32) { this.v = v; } get(): int32 { return this.v; } }
class Base { v: int32 = 1; m(): int32 { return 1; } get twice(): int32 { return this.v * 2; } }
class D extends Base { m(): int32 { return 2 + this.v; } }
class Plain { v: int32 = 0; w: int32 = 2; }
class Box<T> { item: T; constructor(item: T) { this.item = item; } show(): string { return `box ${this.item}`; } }

const own: Counter = { v: 4 };
const d: D = { v: 3 };
const b: Base = d;
const cell: Cell = { v: 4 };
const base = new Cell();
const spread: Cell = { ...base, v: 9 };
const plain: Plain = { v: 4 };
const boxed: Box<int32> = { item: 7 };
console.log(`own ${own.v} ${own.get()} ${own instanceof Counter} | virtual ${b.m()} ${d.m()} ${d.twice} ${d instanceof D} ${b instanceof Base} | spread ${spread.v} ${spread.get()} | imported ${cell.get()} ${cell instanceof Cell} | plain ${plain.v} ${plain.w} ${plain instanceof Plain} | generic ${boxed.show()}`);
