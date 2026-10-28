import { run } from "./b";
export class Wrapper { name: string = ""; }
export function `+`(this w: Wrapper, n: int32): Wrapper { w.name = "new"; return w; }
export function hidden(w: Wrapper): string { w + 1; return "!"; }
export function again(): void { run(); }
