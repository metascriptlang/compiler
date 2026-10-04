// Parity program — a value struct allocated through Ref<S> inside a function links and
// runs: the cell's TypeInfo names the struct's destroy hook, so the hook stays reachable
// whether the struct owns a managed field or none, a sized array of scalars or of structs,
// and at module level too.
//
// @stdout: 13|14|ok-7|3|6|4
// @exit: 0

struct Plain { n: int32; }
struct Named { label: string; n: int32; }

function plain(): int32 {
	const a: Ref<Plain> = { n: 13 };
	return a.n;
}

function named(): string {
	const b: Ref<Named> = { label: "ok", n: 7 };
	return `${b.label}-${b.n}`;
}

struct Roster { count: uint8; xs: int64[4]; }
struct Fighter { hp: int32; atk: int32; }
struct Squad { n: uint8; fs: Fighter[4]; }

function squadAtk(): int32 {
	const s: Ref<Squad> = { n: 2, fs: [{ hp: 1, atk: 2 }, { hp: 3, atk: 4 }, { hp: 5, atk: 6 }, { hp: 7, atk: 8 }] };
	return s.fs[2].atk;
}

const roster: Ref<Roster> = { count: 4, xs: [1, 2, 3, 4] };

console.log(`${plain()}|${plain() + 1}|${named()}|${roster.xs[2]}|${squadAtk()}|${roster.count}`);
