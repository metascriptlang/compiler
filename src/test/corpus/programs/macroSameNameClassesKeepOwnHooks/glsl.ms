import { Body, Pair, Stage } from "./ir";

class Printer {
	stage: Stage = Stage.Vertex;
	names: string[] = [];
	pairs: Pair[] = [];
	current: Body = new Body();
	label: string = "g";
}

export function printGlsl(n: int32): string {
	let out = "";
	for (let i = 0; i < n; i++) {
		const p = new Printer();
		p.names.push("x" + i.toString());
		p.pairs.push({ name: "p" + i.toString(), unit: i });
		p.current.lines.push("l");
		out = out + p.label + p.names.join(",") + p.pairs[0].name + p.current.lines.length.toString();
	}
	return out;
}

export function glslName(): string {
	return "glsl";
}

export class Frame {
	tag: string;
	slots: string[] = [];

	constructor(tag: string) {
		this.tag = tag;
	}
}

export function frameGlsl(n: int32): string {
	const f = new Frame("fg");
	for (let i = 0; i < n; i++) f.slots.push(i.toString());
	return f.tag + f.slots.join("");
}
