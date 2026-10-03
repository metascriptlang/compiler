import { Shape, Holder } from "./shapes";
export class Square extends Shape { corner: string; constructor(c: string) { super("other"); this.corner = c; } area(): number { return 1; } }
export function makeOther(c: string): Shape { return new Square(c); }
export function holdMore(n: string): Holder<string> { return new Holder<string>(n + "!"); }
export function isOtherSquare(s: Shape): boolean { return s instanceof Square; }
