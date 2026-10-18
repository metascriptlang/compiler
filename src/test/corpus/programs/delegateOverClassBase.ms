// @stdout: (1, 2) (1, 2) 3:(1, 2) x=1 (1, 2) | moved (4, 2) (4, 2)
// note: a distinct over a class holds the same object as its base, so a delegated routine receives that object itself, through method syntax, call syntax and a second parameter, a delegated type reads its fields, a generic distinct delegates the same way, and a write through it is seen by the base. Same output on every backend.

class Point { x: int32 = 0; y: int32 = 0; constructor(x: int32, y: int32) { this.x = x; this.y = y; } }
function label(this p: Point): string { return `(${p.x}, ${p.y})`; }
function tagged(n: int32, p: Point): string { return `${n}:(${p.x}, ${p.y})`; }
function shift(this p: Point, dx: int32): void { p.x = p.x + dx; }

type Spot = distinct Point;
@delegate function label(this s: Spot): string;
@delegate function tagged(n: int32, s: Spot): string;
@delegate function shift(this s: Spot, dx: int32): void;

@delegate type Pin = distinct Point;
type Held<T> = distinct Point;
@delegate function label<T>(this h: Held<T>): string;

const base = new Point(1, 2);
const sp = base as Spot;
const pin = base as Pin;
const held = base as Held<int32>;
const before = `${sp.label()} ${label(sp)} ${tagged(3, sp)} x=${pin.x} ${held.label()}`;
sp.shift(3);
console.log(`${before} | moved ${base.label()} ${sp.label()}`);
