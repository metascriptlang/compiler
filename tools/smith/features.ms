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

export enum Plant {
	None,
	Backend,
	Opt,
}

export struct Features {
	types: BitSet<Ty>;
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
	return {
		types: types,
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
	return "types=" + types +
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
	const r = Features.defaults().overlay("types=int32,float64 plant=backend");
	assert r.ok;
	if (r.ok) {
		assert r.value.format() ==
			"types=int32,float64 funcs=5 globals=6 stmts=4 depth=3 expr=3 trips=4 entries=4 plant=backend";
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
