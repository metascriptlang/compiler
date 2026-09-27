export class Box {
	w: number;
	constructor(w: number) { this.w = w; }
	show(): string { return "B" + String(this.w * 2); }
}

class Tag { n: int32; label: string; constructor(label: string) { this.n = 7; this.label = label; } text(): string { return "b:" + this.label + String(this.n); } }
export function tagB(): string { return new Tag("y").text(); }
