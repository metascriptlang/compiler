import { Rng, seeded } from "./rng";

export enum Ty {
	Int8,
	Int16,
	Int32,
	Int64,
	Uint8,
	Uint16,
	Uint32,
	Uint64,
	Float64,
}

export enum Fam {
	Closure,
	Union,
	Generic,
}

export enum Plant {
	None,
	Backend,
	Opt,
}

export struct Features {
	types: BitSet<Ty>;
	fams: BitSet<Fam>;
	funcs: int32;
	globals: int32;
	stmts: int32;
	depth: int32;
	exprDepth: int32;
	trips: int32;
	entries: int32;
	plant: Plant;
}

export const ALL_TYS: Ty[] = [
	Ty.Int8,
	Ty.Int16,
	Ty.Int32,
	Ty.Int64,
	Ty.Uint8,
	Ty.Uint16,
	Ty.Uint32,
	Ty.Uint64,
	Ty.Float64,
];

export const ALL_FAMS: Fam[] = [Fam.Closure, Fam.Union, Fam.Generic];

export function famName(f: Fam): string {
	return match (f) {
		Fam.Closure => "closure",
		Fam.Union => "union",
		Fam.Generic => "generic",
	};
}

function famFromName(name: string): Result<Fam, string> {
	for (const f of ALL_FAMS) {
		if (famName(f) == name) { return Result.ok(f); }
	}
	return Result.err("unknown family '" + name + "' (closure, union, generic, none)");
}

export function tyName(t: Ty): string {
	return match (t) {
		Ty.Int8 => "int8",
		Ty.Int16 => "int16",
		Ty.Int32 => "int32",
		Ty.Int64 => "int64",
		Ty.Uint8 => "uint8",
		Ty.Uint16 => "uint16",
		Ty.Uint32 => "uint32",
		Ty.Uint64 => "uint64",
		Ty.Float64 => "float64",
	};
}

function tyFromName(name: string): Result<Ty, string> {
	for (const t of ALL_TYS) {
		if (tyName(t) == name) { return Result.ok(t); }
	}
	return Result.err("unknown type '" + name + "'");
}

function plantName(p: Plant): string {
	return match (p) {
		Plant.None => "none",
		Plant.Backend => "backend",
		Plant.Opt => "opt",
	};
}

function plantFromName(name: string): Result<Plant, string> {
	return match (name) {
		"none" => Result.ok(Plant.None),
		"backend" => Result.ok(Plant.Backend),
		"opt" => Result.ok(Plant.Opt),
		_ => Result.err("unknown plant '" + name + "' (none, backend, opt)"),
	};
}

export function defaults(this typeof Features): Features {
	let types = 0 as BitSet<Ty>;
	for (const t of ALL_TYS) { types = types.incl(t); }
	let fams = 0 as BitSet<Fam>;
	for (const f of ALL_FAMS) { fams = fams.incl(f); }
	return {
		types: types,
		fams: fams,
		funcs: 5,
		globals: 6,
		stmts: 4,
		depth: 3,
		exprDepth: 3,
		trips: 4,
		entries: 4,
		plant: Plant.None,
	};
}

export function format(this f: Features): string {
	let types = "";
	for (const t of ALL_TYS) {
		if (f.types.has(t)) { types = types == "" ? tyName(t) : types + "," + tyName(t); }
	}
	let fams = "";
	for (const m of ALL_FAMS) {
		if (f.fams.has(m)) { fams = fams == "" ? famName(m) : fams + "," + famName(m); }
	}
	return "types=" + types +
		" fams=" + (fams == "" ? "none" : fams) +
		" funcs=" + String(f.funcs) +
		" globals=" + String(f.globals) +
		" stmts=" + String(f.stmts) +
		" depth=" + String(f.depth) +
		" expr=" + String(f.exprDepth) +
		" trips=" + String(f.trips) +
		" entries=" + String(f.entries) +
		" plant=" + plantName(f.plant);
}

function boundedInt(key: string, text: string, low: int32, high: int32): Result<int32, string> {
	if (text == "") { return Result.err(key + " has no value"); }
	for (let i = 0; i < text.length; i++) {
		const code = text.charCodeAt(i);
		if (code < 48 || code > 57) { return Result.err(key + "=" + text + " is not a number"); }
	}
	const n = text.parseInt() as int32;
	if (n < low || n > high) {
		return Result.err(key + "=" + text + " is outside " + String(low) + ".." + String(high));
	}
	return Result.ok(n);
}

function parseTypes(text: string): Result<BitSet<Ty>, string> {
	let types = 0 as BitSet<Ty>;
	for (const name of text.split(",")) {
		const t = try tyFromName(name);
		types = types.incl(t);
	}
	if (types.isEmpty()) { return Result.err("types= names no type"); }
	return Result.ok(types);
}

function parseFams(text: string): Result<BitSet<Fam>, string> {
	let fams = 0 as BitSet<Fam>;
	if (text == "none") { return Result.ok(fams); }
	for (const name of text.split(",")) {
		const f = try famFromName(name);
		fams = fams.incl(f);
	}
	return Result.ok(fams);
}

export function swarm(this base: Features, seed: uint64): Features {
	const r = Rng.seeded(seed ^ (0x5357524D53574152 as uint64));
	const density = r.next();
	let types = 0 as BitSet<Ty>;
	for (const t of ALL_TYS) {
		if (base.types.has(t) && r.next() < density) { types = types.incl(t); }
	}
	if (types.isEmpty()) {
		const kept: Ty[] = [];
		for (const t of ALL_TYS) { if (base.types.has(t)) { kept.push(t); } }
		types = types.incl(kept[r.below(kept.length)]);
	}
	let fams = 0 as BitSet<Fam>;
	for (const f of ALL_FAMS) {
		if (base.fams.has(f) && r.next() < density) { fams = fams.incl(f); }
	}
	return { ...base, types: types, fams: fams };
}

export function overlay(this base: Features, text: string): Result<Features, string> {
	let f: Features = { ...base };
	for (const item of text.split(" ")) {
		if (item == "") { continue; }
		const eq = item.indexOf("=");
		if (eq <= 0) { return Result.err("'" + item + "' is not key=value"); }
		const key = item.slice(0, eq);
		const value = item.slice(eq + 1, item.length);
		if (key == "types") {
			f = { ...f, types: try parseTypes(value) };
		} else if (key == "fams") {
			f = { ...f, fams: try parseFams(value) };
		} else if (key == "plant") {
			f = { ...f, plant: try plantFromName(value) };
		} else if (key == "funcs") {
			f = { ...f, funcs: try boundedInt(key, value, 1, 64) };
		} else if (key == "globals") {
			f = { ...f, globals: try boundedInt(key, value, 1, 64) };
		} else if (key == "stmts") {
			f = { ...f, stmts: try boundedInt(key, value, 1, 32) };
		} else if (key == "depth") {
			f = { ...f, depth: try boundedInt(key, value, 1, 8) };
		} else if (key == "expr") {
			f = { ...f, exprDepth: try boundedInt(key, value, 1, 8) };
		} else if (key == "trips") {
			f = { ...f, trips: try boundedInt(key, value, 1, 64) };
		} else if (key == "entries") {
			f = { ...f, entries: try boundedInt(key, value, 1, 64) };
		} else {
			return Result.err("unknown feature '" + key + "'");
		}
	}
	return Result.ok(f);
}

test "the formatted vector parses back to itself" {
	const f = Features.defaults();
	const r = Features.defaults().overlay(f.format());
	assert r.ok;
	if (r.ok) { assert r.value.format() == f.format(); }
}

test "an overlay changes only the keys it names" {
	const base = Features.defaults();
	const r = base.overlay("types=int32,float64 plant=backend");
	assert r.ok;
	if (r.ok) {
		assert r.value.types.has(Ty.Int32) && r.value.types.has(Ty.Float64);
		assert !r.value.types.has(Ty.Int64);
		assert r.value.plant == Plant.Backend;
		assert r.value.fams == base.fams;
		assert r.value.funcs == base.funcs && r.value.depth == base.depth;
	}
}

test "an unknown key is refused" {
	assert !Features.defaults().overlay("speed=9").ok;
}

test "an unknown type is refused" {
	assert !Features.defaults().overlay("types=int32,int128").ok;
}

test "a value outside its range is refused" {
	assert !Features.defaults().overlay("depth=0").ok;
	assert !Features.defaults().overlay("trips=x").ok;
}

test "fams=none formats and parses back" {
	const r = Features.defaults().overlay("fams=none");
	assert r.ok;
	if (r.ok) {
		assert r.value.fams.isEmpty();
		assert r.value.format().contains(" fams=none ");
	}
}

test "an unknown family is refused" {
	assert !Features.defaults().overlay("fams=closure,coroutine").ok;
}

test "swarm samples one density per vector, not a fixed coin per feature" {
	const base = Features.defaults();
	let all = 0;
	let none = 0;
	for (let seed = 0; seed < 4096; seed++) {
		const f = base.swarm(seed as uint64);
		if (f.fams == base.fams) { all++; }
		if (f.fams.isEmpty()) { none++; }
	}
	assert all > 819 && all < 1229;
	assert none > 819 && none < 1229;
}

test "swarm density also correlates a restricted two-family vector" {
	const parsed = Features.defaults().overlay("types=uint64 fams=closure,union");
	assert parsed.ok;
	if (parsed.ok) {
		let both = 0;
		for (let seed = 0; seed < 4096; seed++) {
			const f = parsed.value.swarm(seed as uint64);
			assert f.types == parsed.value.types;
			assert !f.fams.has(Fam.Generic);
			if (f.fams == parsed.value.fams) { both++; }
		}
		assert both > 1228 && both < 1502;
	}
}

test "swarm is a function of seed and base, keeps a type, and stays inside the base" {
	const base = Features.defaults().overlay("types=int8,uint64 fams=union");
	assert base.ok;
	if (base.ok) {
		for (let s = 0; s < 64; s++) {
			const a = base.value.swarm(s as uint64);
			assert a.format() == base.value.swarm(s as uint64).format();
			assert !a.types.isEmpty();
			assert !a.types.has(Ty.Int32);
			assert !a.fams.has(Fam.Closure);
		}
	}
}
