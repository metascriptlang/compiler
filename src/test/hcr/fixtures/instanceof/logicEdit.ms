export class Root { tag: int32 = 0; }
export class Mid extends Root { m: int32 = 1; }
export class Leaf extends Mid { l: int32 = 2; }
export class Sib extends Root {}

export function probe(): int32 {
	let n: int32 = 0;
	const xs: unknown[] = [];
	xs.push(new Root());
	xs.push(new Mid());
	xs.push(new Leaf());
	xs.push(new Sib());
	for (const x of xs) {
		if (x instanceof Root) n += 1;
		if (x instanceof Mid) n += 1;
		if (x instanceof Leaf) n += 1;
		if (x instanceof Sib) n += 1;
	}
	const u: unknown = new Leaf();
	n += (u as Mid).m;
	return n + 1;
}
