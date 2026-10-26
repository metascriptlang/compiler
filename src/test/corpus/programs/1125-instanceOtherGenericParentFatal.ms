// @exit: 1
// @stdout: before 1
// @xfail(danger): --danger drops the forced conversion check, so the wrong downcast reads the other instance's memory instead of stopping

class Box<T> { v: T; constructor(v: T) { this.v = v; } }
class Pair<U> extends Box<U> { w: U; constructor(v: U, w: U) { super(v); this.w = w; } }

function asNumber(u: unknown): number { return (u as Box<number>).v; }

console.log(`before ${asNumber(new Pair<number>(1, 2))}`);
console.log(`after ${asNumber(new Pair<string>("x", "y"))}`);
