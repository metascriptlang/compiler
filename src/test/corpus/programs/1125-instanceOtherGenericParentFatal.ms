// @exit: 1
// @stdout: before 1
// @xfail(danger): --danger drops the forced conversion check, so the wrong downcast reads the other instance's memory instead of stopping
// @xfail(raiser): the Raiser stops at the same conversion with exit 1, but its 'raiser runtime error: invalid object conversion: …' goes to stderr, which the raiser cell keeps apart from the compared output

class Box<T> { v: T; constructor(v: T) { this.v = v; } }
class Pair<U> extends Box<U> { w: U; constructor(v: U, w: U) { super(v); this.w = w; } }

function asNumber(u: unknown): number { return (u as Box<number>).v; }

console.log(`before ${asNumber(new Pair<number>(1, 2))}`);
console.log(`after ${asNumber(new Pair<string>("x", "y"))}`);
