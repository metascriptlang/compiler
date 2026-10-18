export class Shape { name: string; constructor(n: string) { this.name = n; } area(): number { return 0; } }
export class Square extends Shape { side: number; constructor(s: number) { super("square"); this.side = s; } area(): number { return this.side * this.side; } }
export class Holder<T> { item: T; constructor(i: T) { this.item = i; } }
export function makeSquare(s: number): Shape { return new Square(s); }
export function holdName(n: string): Holder<string> { return new Holder<string>(n); }
export function isSquare(s: Shape): boolean { return s instanceof Square; }
