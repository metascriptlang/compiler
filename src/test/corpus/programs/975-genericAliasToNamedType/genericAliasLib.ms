export class Plain { n: int32 = 7; }
export class Holder<T> { v: T; constructor(v: T) { this.v = v; } }
export struct Pt { x: int32; y: int32; }
export type Alias<T> = Plain;
export type Box<T> = Holder<T>;
export type P<T> = Pt;
export function mkPlain(): Plain { return new Plain(); }
export function mkPt(): Pt { return { x: 1, y: 2 }; }
