export class Box {
	w: number;
	constructor(w: number) { this.w = w; }
	show(): string { return "B" + String(this.w * 2); }
}
