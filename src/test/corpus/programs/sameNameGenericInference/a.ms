export class Box<T> { v: T; constructor(v: T) { this.v = v; } }
export struct Cell<T> { v: T; }

export function boxOr<T>(x: Box<T> | T): string { return "box-or"; }
export function cellOr<T>(x: Cell<T> | T): string { return "cell-or"; }
