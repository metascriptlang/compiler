export class Box {
	v: number;
	constructor(v: number) { this.v = v; }
	show(): string { return "A" + String(this.v); }
}

class Tag { label: string; constructor(label: string) { this.label = label; } text(): string { return "a:" + this.label; } }
export function tagA(): string { return new Tag("x").text(); }
