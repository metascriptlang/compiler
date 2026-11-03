import { Body } from "./ir";

class Printer {
	depth: int32 = 0;
	words: string[] = [];
	head: string = "m";
	scopes: int32[][] = [];
	current: Body = new Body();
}

export function printMsl(n: int32): string {
	let out = "";
	for (let i = 0; i < n; i++) {
		const p = new Printer();
		p.words.push("z" + i.toString());
		p.scopes.push([i]);
		p.current.depth = i;
		out = out + p.head + p.words.join(",") + p.scopes.length.toString() + p.current.depth.toString();
	}
	return out;
}

export function mslName(): string {
	return "msl";
}
