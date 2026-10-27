import { run } from "./b";
export class Box { v: int32 = 7; }
export class Wrapper { items: Box[] = []; }
export function wipe(this ref arr: Box[], n: int32): void { arr = []; }
export function hidden(w: Wrapper): void { w.items.wipe(1); }
export function again(): void { run(); }
