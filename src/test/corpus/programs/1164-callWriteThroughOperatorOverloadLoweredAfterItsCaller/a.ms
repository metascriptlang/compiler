import { run } from "./b";
export class Box { v: int32 = 7; }
export class Wrapper { items: Box[] = []; }
export function `+`(this w: Wrapper, n: int32): Wrapper { w.items = []; return w; }
export function hidden(w: Wrapper): void { w + 1; }
export function again(): void { run(); }
