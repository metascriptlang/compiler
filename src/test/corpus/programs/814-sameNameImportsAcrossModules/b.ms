export const LIMIT: int32 = 40;
export enum Mode { Slow, Fast, Off }
export function describe(m: Mode): string { return m == Mode.Off ? "b-off" : "b-on"; }
export class Box {
	w: number;
	constructor(w: number) { this.w = w; }
	show(): string { return "B" + String(this.w * 2); }
}
