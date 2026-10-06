export class Many {
	total: int32 = 0;
	constructor(...xs: int32[]) { for (const x of xs) { this.total += x; } }
}

export class Joined {
	s: string = "";
	constructor(head: string, ...tail: string[]) { this.s = head; for (const t of tail) { this.s += t; } }
}

export function sum(...xs: int32[]): int32 {
	let t = 0;
	for (const x of xs) { t += x; }
	return t;
}
