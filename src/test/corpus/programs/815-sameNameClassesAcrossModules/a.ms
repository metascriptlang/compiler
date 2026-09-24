export class Box {
	v: number;
	constructor(v: number) { this.v = v; }
	show(): string { return "A" + String(this.v); }
}
