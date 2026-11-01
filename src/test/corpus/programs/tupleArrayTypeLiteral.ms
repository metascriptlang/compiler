// @stdout: 2 k=v z=null 1 2 1 1 3

function count(pairs: [string, string | null][]): int32 { return pairs.length; }

function describe(pairs: [string, string | null][]): string[] {
	const out: string[] = [];
	for (const [k, v] of pairs) { out.push(k + "=" + (v === null ? "null" : v)); }
	return out;
}

const pairs: [string, string | null][] = [["k", "v"], ["z", null]];
const maybe: ([string, int32] | null)[] = [["a", 1], null];
const frozen: readonly [string, string][] = [["k", "v"]];
const nested: [string, string][][] = [[["k", "v"]]];
const built: [string, int32][] = [];
for (let i = 0; i < 3; i += 1) { built.push(["n", i]); }

console.log(count(pairs).toString() + " " + describe(pairs).join(" ") + " " + maybe.filter((m) => m !== null).length.toString() + " " + maybe.length.toString() + " " + frozen.length.toString() + " " + nested.length.toString() + " " + built.length.toString());
