import { run } from "./b";
export class Box { v: int32 = 7; }
export class Wrapper { items: Box[] = []; }

export function hidden(w: Wrapper): void { w.items.pop(); }
export function again(): void { run(); }
