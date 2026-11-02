// @stdout: forward 6 6
// @stdout: swapped 3 3
// @stdout: try 8 8 ok
// @stdout: hookless 4 4
struct Group { n: int32; tags: string[] }
struct Store { groups: Group[]; total: int32 }
struct Plain { n: int32 }
struct PlainStore { groups: Plain[]; total: int32 }

function bump(ref s: Store, ref g: Group): void {
	g.n += 1;
	s.total += g.n;
}
function step(ref s: Store, i: int32): void {
	bump(s, s.groups[i]);
}

function bumpSwapped(ref g: Group, ref s: Store): void {
	g.n += 2;
	s.total += g.n;
}
function stepSwapped(ref s: Store, i: int32): void {
	bumpSwapped(s.groups[i], s);
}

function bumpChecked(ref s: Store, ref g: Group): Result<int32, string> {
	if (g.tags.length > 4) return Result.err("too many");
	g.n += 3;
	s.total += g.n;
	return Result.ok(s.total);
}
function stepChecked(ref s: Store, i: int32): Result<void, string> {
	try bumpChecked(s, s.groups[i]);
	return Result.ok(null);
}

function bumpPlain(ref s: PlainStore, ref g: Plain): void {
	g.n += 1;
	s.total += g.n;
}
function stepPlain(ref s: PlainStore, i: int32): void {
	bumpPlain(s, s.groups[i]);
}

let s: Store = { groups: [{ n: 1, tags: ["a"] }, { n: 5, tags: [] }], total: 0 };
step(s, 1);
console.log(`forward ${s.groups[1].n} ${s.total}`);

let t: Store = { groups: [{ n: 1, tags: ["a"] }], total: 0 };
stepSwapped(t, 0);
console.log(`swapped ${t.groups[0].n} ${t.total}`);

let u: Store = { groups: [{ n: 5, tags: ["x"] }], total: 0 };
const r = stepChecked(u, 0);
console.log(`try ${u.groups[0].n} ${u.total} ${r.ok ? "ok" : "err"}`);

let p: PlainStore = { groups: [{ n: 0 }, { n: 3 }], total: 0 };
stepPlain(p, 1);
console.log(`hookless ${p.groups[1].n} ${p.total}`);
