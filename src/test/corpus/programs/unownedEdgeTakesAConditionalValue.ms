// @skip-js: C-only by design: the check is that the DRC frees each target exactly once; JS frees nothing
// @stdout: s0 -> s1 / s1 -> s2 / s2 -> s3 / s3 -> none
// @stdout: s0 -> s1 / s1 -> s2 / s2 -> s3 / s3 -> none
// @stdout: kept s1 s2
// note: a conditional, a `??` or an `||` stored into an Unowned<T> slot is a value of T: its temporary holds the target strongly and gives it up once, so the store leaves the target's own count alone and every target is read after the store.
class S {
	name: string;
	up: Unowned<S> | null;
	ups: (Unowned<S> | null)[];
}
function make(name: string): S { return { name, up: null, ups: [] }; }
const syms: S[] = [];
for (let i = 0; i < 4; i += 1) syms.push(make("s" + i));
const idx: int32[] = [1, 2, 3, -1];
for (let i = 0; i < syms.length; i += 1) {
	const s = syms[i];
	s.up = idx[i] >= 0 && idx[i] < syms.length ? syms[idx[i]] : null;
	s.ups.push(idx[i] >= 0 ? syms[idx[i]] : null);
}
for (let k = 0; k < 2; k += 1) {
	const line: string[] = [];
	for (const s of syms) {
		const u = s.up;
		line.push(s.name + " -> " + (u != null ? u!.name : "none"));
	}
	console.log(line.join(" / "));
}
const first = syms[0];
const fallback: S | null = null;
first.up = fallback ?? syms[1];
const second: S = { name: "x", up: syms[1] != null ? syms[2] : null, ups: [] };
console.log("kept " + (first.up != null ? first.up!.name : "none") + " " + (second.up != null ? second.up!.name : "none"));
