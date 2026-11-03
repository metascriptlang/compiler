import { Body, Pair, Stage } from "./ir";

class Printer {
	count: int32 = 0;
	extra: string = "w";
	current: Body = new Body();
	items: string[] = [];
	tail: string[][] = [];
	unhoistable: string = "";
	pairs: Pair[] = [];
	stage: Stage = Stage.Fragment;
}

export function printWgsl(n: int32): string {
	let out = "";
	for (let i = 0; i < n; i++) {
		const p = new Printer();
		p.items.push("y" + i.toString());
		p.tail.push(["t"]);
		p.pairs.push({ name: "q" + i.toString(), unit: i });
		p.count = i;
		out = out + p.extra + p.items.join(",") + p.tail.length.toString() + p.pairs[0].name + p.count.toString();
	}
	return out;
}

export function wgslName(): string {
	return "wgsl";
}

export class Frame {
	depth: int32 = 0;
	parts: string[][] = [];
	name: string;

	constructor(name: string) {
		this.name = name;
	}
}

export function frameWgsl(n: int32): string {
	const f = new Frame("fw");
	for (let i = 0; i < n; i++) f.parts.push([i.toString()]);
	f.depth = n;
	return f.name + f.parts.length.toString() + f.depth.toString();
}
