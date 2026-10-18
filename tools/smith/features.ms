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
	Agg,
	Coll,
	Str,
	Own,
	Iter,
	Seq,
	Gcls,
	Enum,
	Exc,
	Native,
	Spawn,
	Actor,
	Race,
}

export enum W {
	ExprLeaf,
	ExprBinary,
	ExprUnary,
	ExprConvert,
	ExprTernary,
	ExprCall,
	StmtLet,
	StmtAssign,
	StmtCompound,
	StmtIf,
	StmtFor,
	StmtMatch,
	StmtBreak,
	StmtReturn,
	FamClosure,
	FamUnion,
	FamGeneric,
	FamAgg,
	FamColl,
	FamStr,
	FamOwn,
	FamIter,
	FamSeq,
	FamGcls,
	FamEnum,
	FamExc,
	FamNative,
	FamSpawn,
	FamActor,
	FamRace,
	ClosureNamed,
	ClosureArray,
	ClosureIife,
	ClosureDecl,
	ClosureEffect,
	ClosureInvoke,
	ClosureMaker,
	ClosureFill,
	ClosureRoutine,
	GenericId,
	GenericTwice,
	GenericPick,
	GenericMap,
	GenericBox,
	AggField,
	AggMethod,
	AggFresh,
	AggEq,
	AggStruct,
	AggCopy,
	AggWrite,
	AggRef,
	AggClass,
	AggAlias,
	AggPoke,
	CollIndex,
	CollSize,
	CollGet,
	CollSlot,
	CollRest,
	CollDecl,
	CollAlias,
	CollPush,
	CollEdit,
	CollLoop,
	CollSplit,
	CollKeyed,
	CollFixed,
	StrSize,
	StrCode,
	StrTest,
	StrDecl,
	StrAppend,
	StrAssign,
	StrConcat,
	StrText,
	StrCut,
	StrCase,
	StrGrow,
	StrEdit,
	OwnField,
	OwnHeld,
	OwnDecl,
	OwnCopy,
	OwnMove,
	OwnRef,
	OwnOut,
	OwnSink,
	IterNth,
	IterLast,
	IterDecl,
	IterDrain,
	IterManual,
	SeqElem,
	SeqSize,
	SeqSpan,
	SeqBorrow,
	SeqTuple,
	SeqTupleEdit,
	SeqVec,
	SeqVecEdit,
	SeqSpread,
	SeqDestruct,
	SeqRest,
	SeqSpanSet,
	SeqRef,
	SeqMove,
	SeqLoop,
	GclsCell,
	GclsMap,
	GclsNest,
	GclsPair,
	GclsStack,
	GclsBest,
	GclsWrap,
	GclsDecl,
	GclsSet,
	GclsRef,
	GclsOwn,
	EnumNumeric,
	EnumMatch,
	EnumBitset,
	EnumAlias,
	EnumDistinct,
	EnumLiteral,
	EnumDisc,
	EnumUnknown,
	EnumNever,
	ExcCatch,
	ExcFinally,
	ExcRethrow,
	ExcUnwind,
	ExcDefer,
	ExcDeferLoop,
	ExcRecover,
	ExcResult,
	ExcNarrow,
	ExcWrap,
	ExcOrElse,
	ExcNullable,
	NativePtr,
	NativeRef,
	NativeArith,
	NativeHeap,
	NativeLibc,
	NativeCstr,
	NativeOut,
	NativeSink,
	NativeRead,
	NativeSize,
	NativeView,
	SpawnFan,
	SpawnAll,
	SpawnMove,
	SpawnShare,
	SpawnLocked,
	SpawnArc,
	SpawnNest,
	SpawnFail,
	SpawnTimed,
	ActorState,
	ActorCall,
	ActorChain,
	ActorMany,
	ActorSpawn,
	ActorStop,
	RaceFirst,
	RaceTie,
	RaceAny,
	RaceFail,
	RaceAbort,
	RaceTimer,
	ExprFam,
	StmtFam,
	StmtElse,
	UnionLen,
}

export const W_KEYS: string[] = [
	"w.expr.leaf",
	"w.expr.binary",
	"w.expr.unary",
	"w.expr.convert",
	"w.expr.ternary",
	"w.expr.call",
	"w.stmt.let",
	"w.stmt.assign",
	"w.stmt.compound",
	"w.stmt.if",
	"w.stmt.for",
	"w.stmt.match",
	"w.stmt.break",
	"w.stmt.return",
	"w.fam.closure",
	"w.fam.union",
	"w.fam.generic",
	"w.fam.agg",
	"w.fam.coll",
	"w.fam.str",
	"w.fam.own",
	"w.fam.iter",
	"w.fam.seq",
	"w.fam.gcls",
	"w.fam.enum",
	"w.fam.exc",
	"w.fam.native",
	"w.fam.spawn",
	"w.fam.actor",
	"w.fam.race",
	"w.closure.named",
	"w.closure.array",
	"w.closure.iife",
	"w.closure.decl",
	"w.closure.effect",
	"w.closure.invoke",
	"w.closure.maker",
	"w.closure.fill",
	"w.closure.routine",
	"w.generic.id",
	"w.generic.twice",
	"w.generic.pick",
	"w.generic.map",
	"w.generic.box",
	"w.agg.field",
	"w.agg.method",
	"w.agg.fresh",
	"w.agg.eq",
	"w.agg.struct",
	"w.agg.copy",
	"w.agg.write",
	"w.agg.ref",
	"w.agg.class",
	"w.agg.alias",
	"w.agg.poke",
	"w.coll.index",
	"w.coll.size",
	"w.coll.get",
	"w.coll.slot",
	"w.coll.rest",
	"w.coll.decl",
	"w.coll.alias",
	"w.coll.push",
	"w.coll.edit",
	"w.coll.loop",
	"w.coll.split",
	"w.coll.keyed",
	"w.coll.fixed",
	"w.str.size",
	"w.str.code",
	"w.str.test",
	"w.str.decl",
	"w.str.append",
	"w.str.assign",
	"w.str.concat",
	"w.str.text",
	"w.str.cut",
	"w.str.case",
	"w.str.grow",
	"w.str.edit",
	"w.own.field",
	"w.own.held",
	"w.own.decl",
	"w.own.copy",
	"w.own.move",
	"w.own.ref",
	"w.own.out",
	"w.own.sink",
	"w.iter.nth",
	"w.iter.last",
	"w.iter.decl",
	"w.iter.drain",
	"w.iter.manual",
	"w.seq.elem",
	"w.seq.size",
	"w.seq.span",
	"w.seq.borrow",
	"w.seq.tuple",
	"w.seq.tupleEdit",
	"w.seq.vec",
	"w.seq.vecEdit",
	"w.seq.spread",
	"w.seq.destruct",
	"w.seq.rest",
	"w.seq.spanSet",
	"w.seq.ref",
	"w.seq.move",
	"w.seq.loop",
	"w.gcls.cell",
	"w.gcls.map",
	"w.gcls.nest",
	"w.gcls.pair",
	"w.gcls.stack",
	"w.gcls.best",
	"w.gcls.wrap",
	"w.gcls.decl",
	"w.gcls.set",
	"w.gcls.ref",
	"w.gcls.own",
	"w.enum.numeric",
	"w.enum.match",
	"w.enum.bitset",
	"w.enum.alias",
	"w.enum.distinct",
	"w.enum.literal",
	"w.enum.disc",
	"w.enum.unknown",
	"w.enum.never",
	"w.exc.catch",
	"w.exc.finally",
	"w.exc.rethrow",
	"w.exc.unwind",
	"w.exc.defer",
	"w.exc.deferloop",
	"w.exc.recover",
	"w.exc.result",
	"w.exc.narrow",
	"w.exc.wrap",
	"w.exc.orelse",
	"w.exc.nullable",
	"w.native.ptr",
	"w.native.ref",
	"w.native.arith",
	"w.native.heap",
	"w.native.libc",
	"w.native.cstr",
	"w.native.out",
	"w.native.sink",
	"w.native.read",
	"w.native.size",
	"w.native.view",
	"w.spawn.fan",
	"w.spawn.all",
	"w.spawn.move",
	"w.spawn.share",
	"w.spawn.locked",
	"w.spawn.arc",
	"w.spawn.nest",
	"w.spawn.fail",
	"w.spawn.timed",
	"w.actor.state",
	"w.actor.call",
	"w.actor.chain",
	"w.actor.many",
	"w.actor.spawn",
	"w.actor.stop",
	"w.race.first",
	"w.race.tie",
	"w.race.any",
	"w.race.fail",
	"w.race.abort",
	"w.race.timer",
	"w.expr.fam",
	"w.stmt.fam",
	"w.stmt.else",
	"w.union.len",
];

export const W_DEFAULTS: int32[] = [
	25, 30, 8, 10, 8, 19,
	25, 25, 8, 12, 12, 6, 6, 6,
	1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
	1, 1, 1,
	1, 1, 1, 1, 1, 1,
	1, 1, 1, 1, 2,
	1, 1, 1, 1,
	1, 1, 1, 1, 1, 1, 1,
	1, 1, 1, 1, 1,
	1, 1, 1, 1, 1, 1, 1, 1,
	1, 1, 1,
	1, 1, 1,
	1, 1, 1, 1, 1, 1,
	1, 1,
	1, 1, 1, 1, 1, 1,
	1, 1,
	1, 1, 1,
	1, 1, 1, 1,
	1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
	1, 1, 1, 1, 1, 1, 1,
	1, 1, 1, 1,
	1, 1, 1, 1, 1, 1, 1, 1, 1,
	1, 1, 1, 1, 1, 1, 1, 1, 1,
	1, 1, 1,
	1, 1, 1, 1, 1, 1, 1, 1,
	1, 1, 1,
	1, 1, 1, 1, 1, 1, 1, 1, 1,
	1, 1, 1, 1, 1, 1,
	1, 1, 1, 1, 1, 1,
	20, 20, 50, 30,
];

const W_GROUPS: W[][] = [
	[W.ExprLeaf, W.ExprCall],
	[W.StmtLet, W.StmtReturn],
	[W.FamClosure, W.FamRace],
	[W.ClosureNamed, W.ClosureIife],
	[W.ClosureDecl, W.ClosureRoutine],
	[W.GenericId, W.GenericBox],
	[W.AggField, W.AggEq],
	[W.AggStruct, W.AggPoke],
	[W.CollIndex, W.CollRest],
	[W.CollDecl, W.CollFixed],
	[W.StrSize, W.StrTest],
	[W.StrDecl, W.StrAssign],
	[W.StrConcat, W.StrEdit],
	[W.OwnField, W.OwnHeld],
	[W.OwnDecl, W.OwnSink],
	[W.IterNth, W.IterLast],
	[W.IterDecl, W.IterManual],
	[W.SeqElem, W.SeqBorrow],
	[W.SeqTuple, W.SeqLoop],
	[W.GclsCell, W.GclsWrap],
	[W.GclsDecl, W.GclsOwn],
	[W.EnumNumeric, W.EnumNever],
	[W.ExcCatch, W.ExcNarrow],
	[W.ExcWrap, W.ExcNullable],
	[W.NativePtr, W.NativeSink],
	[W.NativeRead, W.NativeView],
	[W.SpawnFan, W.SpawnTimed],
	[W.ActorState, W.ActorStop],
	[W.RaceFirst, W.RaceTimer],
];

export enum Plant {
	None,
	Backend,
	Opt,
	San,
	Model,
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
	top: int32;
	plant: Plant;
	w: int32[];
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

export const ALL_FAMS: Fam[] = [Fam.Closure, Fam.Union, Fam.Generic, Fam.Agg, Fam.Coll, Fam.Str, Fam.Own, Fam.Iter, Fam.Seq, Fam.Gcls, Fam.Enum, Fam.Exc, Fam.Native, Fam.Spawn, Fam.Actor, Fam.Race];
export const OPT_IN_FAMS: Fam[] = [Fam.Native, Fam.Spawn, Fam.Actor, Fam.Race];

export function famName(f: Fam): string {
	return match (f) {
		Fam.Closure => "closure",
		Fam.Union => "union",
		Fam.Generic => "generic",
		Fam.Agg => "agg",
		Fam.Coll => "coll",
		Fam.Str => "str",
		Fam.Own => "own",
		Fam.Iter => "iter",
		Fam.Seq => "seq",
		Fam.Gcls => "gcls",
		Fam.Enum => "enum",
		Fam.Exc => "exc",
		Fam.Native => "native",
		Fam.Spawn => "spawn",
		Fam.Actor => "actor",
		Fam.Race => "race",
	};
}

function famFromName(name: string): Result<Fam, string> {
	for (const f of ALL_FAMS) {
		if (famName(f) == name) { return Result.ok(f); }
	}
	return Result.err("unknown family '" + name + "' (closure, union, generic, agg, coll, str, own, iter, seq, gcls, enum, exc, native, spawn, actor, race, none)");
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
		Plant.San => "san",
		Plant.Model => "model",
	};
}

function plantFromName(name: string): Result<Plant, string> {
	return match (name) {
		"none" => Result.ok(Plant.None),
		"backend" => Result.ok(Plant.Backend),
		"opt" => Result.ok(Plant.Opt),
		"san" => Result.ok(Plant.San),
		"model" => Result.ok(Plant.Model),
		_ => Result.err("unknown plant '" + name + "' (none, backend, opt, san, model)"),
	};
}

export function defaults(this typeof Features): Features {
	let types = 0 as BitSet<Ty>;
	for (const t of ALL_TYS) { types = types.incl(t); }
	let fams = 0 as BitSet<Fam>;
	for (const f of ALL_FAMS) { fams = fams.incl(f); }
	for (const f of OPT_IN_FAMS) { fams = fams.excl(f); }
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
		top: 1,
		plant: Plant.None,
		w: W_DEFAULTS.map((n: int32): int32 => n),
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
		" top=" + String(f.top) +
		" plant=" + plantName(f.plant) + weightText(f.w);
}

function weightText(w: int32[]): string {
	let out = "";
	for (let i = 0; i < W_KEYS.length; i++) {
		if (w[i] != W_DEFAULTS[i]) { out += " " + W_KEYS[i] + "=" + String(w[i]); }
	}
	return out;
}

function weightIndex(key: string): int32 {
	for (let i = 0; i < W_KEYS.length; i++) {
		if (W_KEYS[i] == key) { return i; }
	}
	return -1;
}

function weightsSound(w: int32[]): Result<boolean, string> {
	for (const g of W_GROUPS) {
		let sum = 0;
		for (let i = g[0] as int32; i <= (g[1] as int32); i++) { sum += w[i]; }
		if (sum == 0) {
			return Result.err(W_KEYS[g[0] as int32] + " .. " + W_KEYS[g[1] as int32] + " are all 0; one must be positive");
		}
	}
	return Result.ok(true);
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
		} else if (key == "top") {
			f = { ...f, top: try boundedInt(key, value, 0, 8) };
		} else if (key.startsWith("w.")) {
			const at = weightIndex(key);
			if (at < 0) { return Result.err("unknown weight '" + key + "'"); }
			const n = try boundedInt(key, value, 0, 100);
			const next = f.w.map((x: int32): int32 => x);
			next[at] = n;
			f = { ...f, w: next };
		} else {
			return Result.err("unknown feature '" + key + "'");
		}
	}
	const sound = weightsSound(f.w);
	if (!sound.ok) { return Result.err(sound.error); }
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

test "default weights print nothing and a changed weight prints only itself" {
	assert !Features.defaults().format().contains(" w.");
	const r = Features.defaults().overlay("w.expr.ternary=80 w.stmt.fam=0");
	assert r.ok;
	if (r.ok) {
		const text = r.value.format();
		assert text.endsWith(" w.expr.ternary=80 w.stmt.fam=0");
		assert !text.contains("w.expr.leaf");
	}
}

test "a weight vector parses back to itself" {
	const r = Features.defaults().overlay("fams=closure w.expr.call=0 w.fam.union=7 w.closure.iife=3");
	assert r.ok;
	if (r.ok) {
		const back = Features.defaults().overlay(r.value.format());
		assert back.ok;
		if (back.ok) { assert back.value.format() == r.value.format(); }
	}
}

test "setting a weight back to its default prints nothing" {
	const r = Features.defaults().overlay("w.expr.leaf=3 w.expr.leaf=25");
	assert r.ok;
	if (r.ok) { assert r.value.format() == Features.defaults().format(); }
}

test "an overlay never changes the weights of its base" {
	const base = Features.defaults();
	const r = base.overlay("w.expr.leaf=3");
	assert r.ok;
	assert base.w[0] == 25;
}

test "an unknown weight, a bad value and an all-zero group are refused" {
	assert !Features.defaults().overlay("w.expr.nope=3").ok;
	assert !Features.defaults().overlay("w.expr.leaf=101").ok;
	assert !Features.defaults().overlay("w.expr.leaf=x").ok;
	assert !Features.defaults().overlay("w.expr.leaf=0 w.expr.binary=0 w.expr.unary=0 w.expr.convert=0 w.expr.ternary=0 w.expr.call=0").ok;
	assert !Features.defaults().overlay("w.fam.closure=0 w.fam.union=0 w.fam.generic=0 w.fam.agg=0 w.fam.coll=0 w.fam.str=0 w.fam.own=0 w.fam.iter=0 w.fam.seq=0 w.fam.gcls=0 w.fam.enum=0 w.fam.exc=0 w.fam.native=0 w.fam.spawn=0 w.fam.actor=0 w.fam.race=0").ok;
}

test "swarm keeps the weights of its base" {
	const base = Features.defaults().overlay("w.expr.ternary=80");
	assert base.ok;
	if (base.ok) {
		for (let s = 0; s < 16; s++) { assert base.value.swarm(s as uint64).format().contains(" w.expr.ternary=80"); }
	}
}

test "weight keys and defaults line up with the enum" {
	assert W_KEYS.length == W_DEFAULTS.length;
	assert W_KEYS.length == (W.UnionLen as int32) + 1;
	assert W_KEYS[W.StmtBreak as int32] == "w.stmt.break";
	assert W_KEYS[W.GenericBox as int32] == "w.generic.box";
}

test "the weight groups tile the grouped keys and each holds one prefix" {
	let next = W.ExprLeaf as int32;
	for (const g of W_GROUPS) {
		assert (g[0] as int32) == next;
		const first = W_KEYS[g[0] as int32];
		const prefix = first.slice(0, first.lastIndexOf(".") + 1);
		for (let i = g[0] as int32; i <= (g[1] as int32); i++) { assert W_KEYS[i].startsWith(prefix); }
		next = (g[1] as int32) + 1;
	}
	assert next == (W.ExprFam as int32);
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
	const expected = 4096 / (ALL_FAMS.length - OPT_IN_FAMS.length + 1);
	assert all > expected * 9 / 10 && all < expected * 135 / 100;
	assert none > expected * 9 / 10 && none < expected * 135 / 100;
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

test "seq and gcls parse by name and their weights round-trip" {
	const r = Features.defaults().overlay("fams=seq,gcls w.seq.rest=0 w.seq.tupleEdit=7 w.gcls.own=3 w.fam.seq=5");
	assert r.ok;
	if (r.ok) {
		assert r.value.fams.has(Fam.Seq) && r.value.fams.has(Fam.Gcls) && !r.value.fams.has(Fam.Closure);
		assert r.value.format().contains(" fams=seq,gcls ");
		const back = Features.defaults().overlay(r.value.format());
		assert back.ok;
		if (back.ok) { assert back.value.format() == r.value.format(); }
	}
	assert !Features.defaults().overlay("w.seq.elem=0 w.seq.size=0 w.seq.span=0 w.seq.borrow=0").ok;
	assert !Features.defaults().overlay("w.gcls.decl=0 w.gcls.set=0 w.gcls.ref=0 w.gcls.own=0").ok;
}

test "plant=model parses, formats back and a near name is refused" {
	const r = Features.defaults().overlay("plant=model");
	assert r.ok;
	if (r.ok) {
		assert r.value.plant == Plant.Model;
		assert r.value.format().contains(" plant=model");
		const back = Features.defaults().overlay(r.value.format());
		assert back.ok;
		if (back.ok) { assert back.value.plant == Plant.Model; }
	}
	assert !Features.defaults().overlay("plant=models").ok;
}

test "the task families parse by name and each shape group refuses an all-zero row" {
	const r = Features.defaults().overlay("fams=spawn,actor,race w.spawn.fan=0 w.actor.stop=3 w.race.timer=2");
	assert r.ok;
	if (r.ok) {
		assert r.value.fams.has(Fam.Spawn) && r.value.fams.has(Fam.Actor) && r.value.fams.has(Fam.Race);
		assert !r.value.fams.has(Fam.Iter);
		assert r.value.format().contains(" fams=spawn,actor,race ");
		assert r.value.format().endsWith(" w.spawn.fan=0 w.actor.stop=3 w.race.timer=2");
	}
	assert !Features.defaults().overlay("fams=spawn,fork").ok;
	assert !Features.defaults().overlay("w.spawn.fan=0 w.spawn.all=0 w.spawn.move=0 w.spawn.share=0 w.spawn.locked=0 w.spawn.arc=0 w.spawn.nest=0 w.spawn.fail=0 w.spawn.timed=0").ok;
	assert !Features.defaults().overlay("w.actor.state=0 w.actor.call=0 w.actor.chain=0 w.actor.many=0 w.actor.spawn=0 w.actor.stop=0").ok;
	assert !Features.defaults().overlay("w.race.first=0 w.race.tie=0 w.race.any=0 w.race.fail=0 w.race.abort=0 w.race.timer=0").ok;
}

test "the default vector leaves out the families that skip a lane or serialize the run" {
	const base = Features.defaults();
	for (const f of OPT_IN_FAMS) { assert !base.fams.has(f); }
	for (const f of ALL_FAMS) {
		let optIn = false;
		for (const o of OPT_IN_FAMS) { if (o == f) { optIn = true; } }
		assert base.fams.has(f) != optIn;
	}
	const r = base.overlay("fams=native,spawn");
	assert r.ok;
	if (r.ok) { assert r.value.fams.has(Fam.Native) && r.value.fams.has(Fam.Spawn); }
}
