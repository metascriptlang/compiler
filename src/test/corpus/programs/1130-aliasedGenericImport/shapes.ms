export class Cell<T> { v: T; constructor(v: T) { this.v = v; } get(): T { return this.v; } }
export struct Pt<T> { x: T; y: T; }
export function idOf<T>(x: T): T { return x; }
