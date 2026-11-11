// @skip-js: C-only by design: the check is that the DRC frees each target exactly once; JS frees nothing
// @xfail(raiser): a counted `||` whose left operand reads an Unowned field stops in the analyzer on the Raiser, on main too; card 2026-11-11-raiser-counted-or-of-an-unowned-read-reaches-the-analyzer-impure
// @stdout: seen 9 root root
// note: a conditional, a `??` or an `||` whose arm reads an Unowned<T> field is a value of T: its temporary holds the target strongly and gives that hold back once, so joining the read leaves the target's own count where it was.
class S {
	name: string;
	up: Unowned<S> | null = null;
	constructor(name: string) { this.name = name; }
}
const keep: S[] = [new S("root")];
const kids: S[] = [];
for (let i = 0; i < 3; i += 1) {
	const k = new S("k" + i);
	k.up = keep[0];
	kids.push(k);
}
let seen = 0;
for (let round = 0; round < 3; round += 1) {
	for (const k of kids) {
		const viaConditional = round >= 0 ? k.up : null;
		const viaNullish = k.up ?? null;
		const viaOr = k.up || null;
		if (viaConditional != null && viaNullish != null && viaOr != null) seen += 1;
	}
}
console.log("seen " + seen + " root " + keep[0].name);
