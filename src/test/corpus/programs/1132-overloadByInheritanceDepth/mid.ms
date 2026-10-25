export class A { a: int32 = 1; }
export class BB extends A { b: int32 = 2; }
export class G<T> extends A { g: T; constructor(g: T) { super(); this.g = g; } }
