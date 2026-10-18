import { Rng, seeded } from "./rng";
import { ALL_TYS, ALL_FAMS, Fam, Features, Plant, Ty, W, W_DEFAULTS, famName, tyName, format } from "./features";

const FN_COST_CAP: int64 = 20000 as int64;
const ROUTINE_FRAMES: int32 = 4;
const TOP_COST_CAP: int64 = 200000 as int64;
const GEN_NODE_CAP: int32 = 4096;
const SEQ_LEN_CAP: int32 = 512;
const SKIP_JS: string = "// @skip-js: pointer arithmetic and C externs have no JS form: the checker refuses the first on JS and an extern has no C linkage there";
const SKIP_RAISER: string = "// @skip-raiser: the raiser refuses pointer arithmetic and has no host bridge for libc externs";
const CLS_CAP: int64 = 60 as int64;
const CLS_MAX: int32 = 5;
const CLS_DEPTH_MAX: int32 = 2;

enum Shape {
	Literal,
	Ternary,
	Other,
}

struct Var {
	name: string;
	ty: Ty;
	writable: boolean;
}

enum EntKind {
	Callable,
	Effect,
	ClosureArray,
	UnionVar,
	BoxVar,
	StructVar,
	ClassVar,
	ArrayVar,
	FixedVar,
	MapVar,
	SetVar,
	StrVar,
	OwnVar,
	HeldVar,
	IterFn,
	TupleVar,
	TupleFrozen,
	VecVar,
	CellVar,
	NestVar,
	PairVar,
	StackVar,
	ItemVar,
	EnumVar,
	NatRec,
	NatRecPtr,
	NatPtr,
	NatRef,
	ClsObj,
	ClsIfv,
	ConvS,
	ConvC,
}

struct Ent {
	kind: EntKind;
	name: string;
	ty: Ty;
	params: Ty[];
	len: int32;
	cost: int64;
}

struct Routine {
	text: string;
	cost: int64;
}

struct NatText {
	text: string;
	bytes: int32;
}

struct Fn {
	name: string;
	ret: Ty;
	params: Ty[];
	cost: int64;
}

struct ClsMember {
	name: string;
	ty: Ty;
	params: Ty[];
	cost: int64;
	owner: int32;
	id: int32;
	vis: int32;
	writable: boolean;
}

class ClsDef {
	name: string = "";
	index: int32 = 0;
	parent: int32 = -1;
	iface: int32 = -1;
	fields: ClsMember[] = [];
	props: ClsMember[] = [];
	methods: ClsMember[] = [];
	statics: ClsMember[] = [];
	smeths: ClsMember[] = [];
	ctor: Ty[] = [];
	ctorCost: int64 = 0 as int64;
}

struct ClsIface {
	name: string;
	fields: ClsMember[];
	ap: ClsMember[];
}

struct ClsRecv {
	text: string;
	cls: int32;
}

function clsMods(vis: int32): string { return vis == 2 ? "private " : vis == 1 ? "protected " : ""; }

function isFloat(t: Ty): boolean { return t == Ty.Float64; }

function isSigned(t: Ty): boolean {
	return t == Ty.Int8 || t == Ty.Int16 || t == Ty.Int32 || t == Ty.Int64;
}

function bitsOf(t: Ty): int32 {
	return match (t) {
		Ty.Int8 | Ty.Uint8 => 8,
		Ty.Int16 | Ty.Uint16 => 16,
		Ty.Int32 | Ty.Uint32 => 32,
		_ => 64,
	};
}

function trapsOnOverflow(t: Ty): boolean { return isSigned(t); }

function posMax(t: Ty): uint64 {
	return match (t) {
		Ty.Int8 => (127 as uint64),
		Ty.Int16 => (32767 as uint64),
		Ty.Int32 => (2147483647 as uint64),
		Ty.Int64 => (9223372036854775807 as uint64),
		Ty.Uint8 => (255 as uint64),
		Ty.Uint16 => (65535 as uint64),
		Ty.Uint32 => (4294967295 as uint64),
		_ => (18446744073709551615 as uint64),
	};
}

function negMax(t: Ty): uint64 {
	return match (t) {
		Ty.Int8 => (128 as uint64),
		Ty.Int16 => (32768 as uint64),
		Ty.Int32 => (2147483648 as uint64),
		Ty.Int64 => (9223372036854775808 as uint64),
		_ => (0 as uint64),
	};
}

function tyTitle(t: Ty): string {
	const name = tyName(t);
	return name.slice(0, 1).toUpperCase() + name.slice(1, name.length);
}

function intLiteral(t: Ty, negative: boolean, magnitude: uint64): string {
	const digits = String(magnitude);
	const minus = negative && magnitude != (0 as uint64);
	if (t == Ty.Int32) {
		if (!minus) { return digits; }
		if (magnitude == (2147483648 as uint64)) { return "((-2147483648) as int32)"; }
		return "(-" + digits + ")";
	}
	return minus ? "((-" + digits + ") as " + tyName(t) + ")" : "(" + digits + " as " + tyName(t) + ")";
}

function zero(t: Ty): string { return isFloat(t) ? "0.0" : intLiteral(t, false, 0 as uint64); }

function minLiteral(t: Ty): string { return intLiteral(t, true, negMax(t)); }

function maxLiteral(t: Ty): string { return intLiteral(t, false, posMax(t)); }

function fitsRaw(from: Ty, to: Ty): boolean {
	if (isFloat(to)) { return true; }
	if (isFloat(from)) { return false; }
	if (!isSigned(to)) { return true; }
	return isSigned(from) ? bitsOf(from) <= bitsOf(to) : bitsOf(from) < bitsOf(to);
}

function floatRangeTest(t: Ty): string {
	return match (t) {
		Ty.Int8 => "x > -129.0 && x < 128.0",
		Ty.Int16 => "x > -32769.0 && x < 32768.0",
		Ty.Int32 => "x > -2147483649.0 && x < 2147483648.0",
		Ty.Int64 => "x >= -9223372036854775808.0 && x < 9223372036854775808.0",
		Ty.Uint8 => "x > -1.0 && x < 256.0",
		Ty.Uint16 => "x > -1.0 && x < 65536.0",
		Ty.Uint32 => "x > -1.0 && x < 4294967296.0",
		_ => "x > -1.0 && x < 18446744073709551616.0",
	};
}

const FLOAT_EDGES: string[] = [
	"0.0",
	"1.0",
	"0.5",
	"0.1",
	"3.0",
	"1.0e300",
	"5.0e-324",
	"1.7976931348623157e308",
	"2.2250738585072014e-308",
	"1.0e-7",
	"1.0e21",
	"123456789.125",
	"1.0e16",
];

const INT_OPS: string[] = ["+", "-", "*", "/", "%", "&", "|", "^", "<<", ">>"];
const FLOAT_OPS: string[] = ["+", "-", "*", "/", "%"];
const CMP_OPS: string[] = ["==", "!=", "<", "<=", ">", ">="];
const STR_CHARS: string[] = ["a", "b", "Z", " ", "é", "ÿ", "中", "-", "0", "\\n", "\\t", "\\\"", "\\\\"];
const STR_TESTS: string[] = [" == ", " != ", " < ", " > ", ".includes(", ".startsWith(", ".endsWith("];

enum EShape {
	Numeric,
	Match,
	Bitset,
	Alias,
	Distinct,
	Literal,
	Disc,
	Unknown,
	Never,
}

const E_SHAPES: EShape[] = [
	EShape.Numeric,
	EShape.Match,
	EShape.Bitset,
	EShape.Alias,
	EShape.Distinct,
	EShape.Literal,
	EShape.Disc,
	EShape.Unknown,
	EShape.Never,
];

struct ETy {
	id: int32;
	shape: EShape;
	name: string;
	ann: string;
	n: int32;
	lits: string[];
}

const FLAG_COUNTS: int32[] = [3, 8, 9, 17, 33, 65];
const LIT_SETS: string[] = ["n,e,s,w", "red,green,blue", "on,off", "lo,mid,hi,max"];
const BIT_OPS: string[] = ["&", "|", "^"];

function quoted(s: string): string { return "\"" + s + "\""; }

const EXC_SKIP_FINALLY: string = "// @skip-raiser: 2026-10-14-raiser-loses-a-finally-when-a-raise-starts-in-catch-or-finally";
const EXC_SKIP_DEFER: string = "// @skip-raiser: 2026-10-19-raiser-defer-in-a-loop-is-skipped-by-continue-and-late-after-break";

const EXC_BASE: string = "class ExcErr extends Error {\n" +
	"\tcode: int32;\n" +
	"\tconstructor(msg: string, code: int32) {\n" +
	"\t\tsuper(msg);\n" +
	"\t\tthis.code = code;\n" +
	"\t}\n}\n" +
	"class ExcErr2 extends ExcErr {\n" +
	"\ttag: string;\n" +
	"\tconstructor(msg: string, code: int32, tag: string) {\n" +
	"\t\tsuper(msg, code);\n" +
	"\t\tthis.tag = tag;\n" +
	"\t}\n}\n" +
	"class ExcObj {\n" +
	"\tname: string;\n" +
	"\txs: int32[];\n" +
	"\tconstructor(name: string, n: int32) {\n" +
	"\t\tthis.name = name;\n" +
	"\t\tthis.xs = [n, n % 1000];\n" +
	"\t}\n}\n" +
	"struct ExcBag { s: string; xs: string[]; n: int32; }\n" +
	"struct ExcFault { code: int32; why: string; }\n" +
	"enum ExcFail { Neg, Big, Odd }\n" +
	"let excLog: int32 = 0;\n" +
	"function excMix(s: string): void {\n" +
	"\tlet h: int32 = excLog;\n" +
	"\tfor (let i: int32 = 0; i < s.length; i++) { h = (h * 31 + (s.charCodeAt(i) as int32)) % 1000003; }\n" +
	"\texcLog = h;\n}\n" +
	"function excFold(tr: string[]): void { excMix(tr.join(\",\")); }\n" +
	"function excErrText(e: ExcFail): string { return e == ExcFail.Neg ? \"neg\" : e == ExcFail.Big ? \"big\" : \"odd\"; }\n";

function utf8Bytes(piece: string): int32 {
	return piece == "é" || piece == "ÿ" ? 2 : piece == "中" ? 3 : 1;
}

function natCheckAt(indent: string, cond: string, what: string): string {
	return indent + "natCheck(" + cond + ", \"" + what + "\");\n";
}

function natSame(t: Ty, a: string, b: string): string {
	return isFloat(t) ? "natSameF64(" + a + ", " + b + ")" : "(" + a + " == " + b + ")";
}

function natVal(t: Ty, j: string): string { return "((" + j + " * 3 + 1) as " + tyName(t) + ")"; }

function natLoop(indent: string, j: string, from: int32, to: int32, body: string): string {
	return indent + "for (let " + j + ": int32 = " + String(from) + "; " + j + " < " + String(to) + "; " + j + "++) { " + body + " }\n";
}

function natBytes(count: int32, T: string): string { return "((" + String(count) + " * sizeof " + T + ") as uint64)"; }

const NAT_EXTERNS: string[] = [
	"natMalloc", "stdlib.h", "(n: uint64): Ptr<void>", "malloc",
	"natCalloc", "stdlib.h", "(c: uint64, n: uint64): Ptr<void>", "calloc",
	"natRealloc", "stdlib.h", "(p: Ptr<void>, n: uint64): Ptr<void>", "realloc",
	"natFree", "stdlib.h", "(p: Ptr<void>): void", "free",
	"natFreeSink", "stdlib.h", "(sink p: Ptr<void>): void", "free",
	"natAtoi", "stdlib.h", "(s: cstring): int32", "atoi",
	"natRandR", "stdlib.h", "(ref seed: uint32): int32", "rand_r",
	"natMemcpy", "string.h", "(d: Ptr<void>, s: Ptr<void>, n: uint64): Ptr<void>", "memcpy",
	"natMemmove", "string.h", "(d: Ptr<void>, s: Ptr<void>, n: uint64): Ptr<void>", "memmove",
	"natMemset", "string.h", "(p: Ptr<void>, c: int32, n: uint64): Ptr<void>", "memset",
	"natMemcmp", "string.h", "(a: Ptr<void>, b: Ptr<void>, n: uint64): int32", "memcmp",
	"natStrlen", "string.h", "(s: cstring): uint64", "strlen",
	"natStrcmp", "string.h", "(a: cstring, b: cstring): int32", "strcmp",
	"natModf", "math.h", "(x: float64, out ip: float64): float64", "modf",
	"natFrexp", "math.h", "(x: float64, out e: int32): float64", "frexp",
	"natFrexpRef", "math.h", "(x: float64, ref e: int32): float64", "frexp",
	"natLdexp", "math.h", "(x: float64, e: int32): float64", "ldexp",
	"natPushS", "", "(this arr: string[], sink value: string): void", "&msStringArrayPush",
];

const TASK_SALT: uint64 = 0x5441534B53414C54 as uint64;
const TASK_COST_CAP: int64 = 100000 as int64;
const WORKER_COST_CAP: int64 = 2000 as int64;
const TASK_NODE_CAP: int32 = 256;
const MAX_TASKS: int32 = 6;
const TICK_CAP: int32 = 6;

struct Worker {
	name: string;
	text: string;
	cost: int64;
}

function isTaskFam(f: Fam): boolean { return f == Fam.Spawn || f == Fam.Actor || f == Fam.Race; }

function wireSafe(t: Ty): boolean { return t != Ty.Int64 && t != Ty.Uint64; }

function joinSafe(t: Ty): boolean { return t == Ty.Int32 || t == Ty.Float64; }

const RACE_TYS: string[] = ["int32", "float64", "boolean"];

const TASK_CHECK: string = "function taskCheck(name: string, par: string, seq: string): void {\n" +
	"\tif (par != seq) { throw new Error(name + \" mismatch \" + par + \" | \" + seq); }\n" +
	"\tconsole.log(name + \" \" + par);\n" +
	"}\n";

function stepName(t: Ty): string { return "step_" + tyName(t); }

function stepText(t: Ty): string {
	const T = tyName(t);
	const head = "function " + stepName(t) + "(s: " + T + ", v: int32): " + T + " {\n";
	if (t == Ty.Int32) { return head + "\treturn (s * 3 + v) % 1000003;\n}\n"; }
	if (isFloat(t)) { return head + "\treturn s * 0.5 + (v as float64);\n}\n"; }
	return head + "\treturn s ^ (v as " + T + ");\n}\n";
}

function foldName(t: Ty): string { return "fold_" + tyName(t); }

function foldText(t: Ty): string {
	const T = tyName(t);
	return "function " + foldName(t) + "(a: Readonly<" + T + "[]>): int32 {\n" +
		"\tlet s: int64 = 7;\n" +
		"\tfor (let i: int32 = 0; i < a.length; i++) { s = (s * 31 + (a[i] as int64)) % 1000003; }\n" +
		"\treturn s as int32;\n" +
		"}\n";
}

function ticksName(t: string): string { return "ticks_" + t; }

function ticksText(t: string): string {
	return "async function " + ticksName(t) + "(v: " + t + ", n: int32): Promise<" + t + "> {\n" +
		"\tfor (let i: int32 = 0; i < n; i++) { await Promise.resolve(0); }\n" +
		"\treturn v;\n" +
		"}\n";
}

function failName(t: string): string { return "fail_" + t; }

function failText(t: string): string {
	return "async function " + failName(t) + "(n: int32, id: int32): Promise<" + t + "> {\n" +
		"\tfor (let i: int32 = 0; i < n; i++) { await Promise.resolve(0); }\n" +
		"\tthrow new Error(\"f\" + String(id));\n" +
		"}\n";
}

function lateName(t: string): string { return "late_" + t; }

function lateText(t: string): string {
	return "async function " + lateName(t) + "(v: " + t + ", ms: int32): Promise<" + t + "> {\n" +
		"\tawait sleepAsync(ms);\n" +
		"\treturn v;\n" +
		"}\n";
}

const SKIP_RAISER_ALL: string = "// @skip-raiser: Promise.all has no host bridge on the Raiser (docs/RAISER.md Status table, row Promise.all: msPromiseAll is unbridged)";
const SKIP_RAISER_RACE: string = "// @skip-raiser: Promise.race and Promise.any have no host bridge on the Raiser (docs/RAISER.md std access: an extern with no bridge fails with Unknown host function; msPromiseRace and msPromiseAny measured 2026-10-19)";
const SKIP_RAISER_CELLS: string = "// @skip-raiser: Locked and Arc have no Raiser constructor and their msLocked externs have no host bridge (docs/RAISER.md std access: an extern with no bridge fails with Unknown host function)";
const SKIP_RAISER_ACTOR: string = "// @skip-raiser: an actor has no Raiser constructor (cannot compile 'new' here: no matching constructor in the Raiser function table; corpus actorSendCallValues.ms line 2 carries the same xfail)";
const SKIP_RAISER_TIMED: string = "// @skip-raiser: a timed spawn has no host bridge on the Raiser (msSpawn is unbridged; docs/RAISER.md std access)";
const SKIP_JS_LOCKED: string = "// @skip-js: Locked<T> is a C-only synchronization cell (docs/KNOWN-ISSUES.md L44)";
const SKIP_JS_ARC: string = "// @skip-js: Arc<T> has no js binding (atomic-rc box is C-only; corpus 414-arcPodPointee.ms line 2)";

class Gen {
	rng: Rng = new Rng();
	tys: Ty[] = [];
	stmtMax: int32 = 1;
	depthMax: int32 = 1;
	exprMax: int32 = 1;
	tripMax: int32 = 1;
	globals: Var[] = [];
	scope: Var[] = [];
	fns: Fn[] = [];
	helperNames: string[] = [];
	helperText: string = "";
	localCount: int32 = 0;
	shape: Shape = Shape.Other;
	loopCount: int32 = 0;
	cost: int64 = 0 as int64;
	costCap: int64 = 0 as int64;
	mult: int64 = 1 as int64;
	fams: Fam[] = [];
	ents: Ent[] = [];
	entCount: int32 = 0;
	makerCount: int32 = 0;
	nodesLeft: int32 = GEN_NODE_CAP;
	w: int32[] = W_DEFAULTS;
	bodyDepth: int32 = 0;
	famShape: Shape = Shape.Other;
	elseArms: int32 = 0;
	atTop: boolean = false;
	arithInElse: int32 = 0;
	blockId: int32 = 0;
	blockCount: int32 = 0;
	directives: string[] = [];
	classes: ClsDef[] = [];
	ifaces: ClsIface[] = [];
	clsSelf: ClsDef = new ClsDef();
	clsBuilding: int32 = 0;
	clsLimit: int32 = 0;
	clsNames: int32 = 0;
	arrowDepth: int32 = 0;
	clsStatics: int32 = -1;
	imports: string[] = [];
	taskFams: Fam[] = [];
	taskText: string = "";
	taskCalls: string = "";
	taskHelperNames: string[] = [];
	taskCount: int32 = 0;
	workCount: int32 = 0;
	taskPlant: boolean = false;
	eTypes: ETy[] = [];
	excCount: int32 = 0;
	matchArms: int32 = 0;
	excHaz: int32 = -1;

	wt(k: W): int32 { return this.w[k as int32]; }

	pickW(first: W, last: W): int32 {
		const from = first as int32;
		let total = 0;
		for (let i = from; i <= (last as int32); i++) { total += this.w[i]; }
		let k = this.rng.below(total);
		for (let i = from; i <= (last as int32); i++) {
			if (k < this.w[i]) { return i - from; }
			k -= this.w[i];
		}
		unreachable;
	}

	famTotal(): int32 {
		let total = 0;
		for (const f of this.fams) { total += this.w[(W.FamClosure as int32) + (f as int32)]; }
		return total;
	}

	pickFam(): Fam {
		let k = this.rng.below(this.famTotal());
		for (const f of this.fams) {
			const n = this.w[(W.FamClosure as int32) + (f as int32)];
			if (k < n) { return f; }
			k -= n;
		}
		unreachable;
	}

	pickTy(): Ty { return this.tys[this.rng.below(this.tys.length)]; }

	pickOp(ops: string[]): string { return ops[this.rng.below(ops.length)]; }

	reserve(work: int64): boolean {
		const remaining = this.costCap - this.cost;
		if (remaining < 0 || work > remaining / this.mult) { return false; }
		this.cost = this.cost + this.mult * work;
		return true;
	}

	spare(times: int64): int64 {
		const remaining = this.costCap - this.cost;
		if (remaining <= 0) { return 0 as int64; }
		const share = remaining / this.mult / times;
		return share < FN_COST_CAP ? share : FN_COST_CAP;
	}

	intTys(): Ty[] {
		const out: Ty[] = [];
		for (const t of this.tys) { if (!isFloat(t)) { out.push(t); } }
		return out;
	}

	magnitudeUpTo(max: uint64): uint64 {
		if (max == (18446744073709551615 as uint64)) { return this.rng.next(); }
		return this.rng.next() % (max + (1 as uint64));
	}

	intLit(t: Ty): string {
		const signed = isSigned(t);
		const k = this.rng.below(10);
		if (k < 4) { return intLiteral(t, signed && this.rng.chance(50), this.rng.below(17) as uint64); }
		if (k < 7) {
			const edge = this.rng.below(signed ? 7 : 4);
			return match (edge) {
				0 => intLiteral(t, false, 0 as uint64),
				1 => intLiteral(t, false, 1 as uint64),
				2 => intLiteral(t, false, posMax(t)),
				3 => intLiteral(t, false, posMax(t) - (1 as uint64)),
				4 => intLiteral(t, true, negMax(t)),
				5 => intLiteral(t, true, negMax(t) - (1 as uint64)),
				_ => intLiteral(t, true, 1 as uint64),
			};
		}
		if (k < 8) {
			const shift = this.rng.below(bitsOf(t) - (signed ? 1 : 0));
			return intLiteral(t, signed && this.rng.chance(50), (1 as uint64) << (shift as uint64));
		}
		const negative = signed && this.rng.chance(50);
		return intLiteral(t, negative, this.magnitudeUpTo(negative ? negMax(t) : posMax(t)));
	}

	floatLit(): string {
		const k = this.rng.below(10);
		let text = "";
		if (k < 3) {
			text = FLOAT_EDGES[this.rng.below(FLOAT_EDGES.length)];
		} else if (k < 7) {
			const frac = String(this.rng.below(1000) + 1000);
			text = String(this.rng.below(100000)) + "." + frac.slice(1, 4);
		} else {
			const frac = String(this.rng.below(1000) + 1000);
			text = String(this.rng.between(1, 9)) + "." + frac.slice(1, 4) + "e" + String(this.rng.between(-40, 40));
		}
		return this.rng.chance(30) ? "(-" + text + ")" : text;
	}

	literal(t: Ty): string { return isFloat(t) ? this.floatLit() : this.intLit(t); }

	visible(t: Ty, writableOnly: boolean): Var[] {
		const out: Var[] = [];
		for (const v of this.scope) {
			if (v.ty == t && (!writableOnly || v.writable)) { out.push(v); }
		}
		for (const v of this.globals) {
			if (v.ty == t) { out.push(v); }
		}
		return out;
	}

	leaf(t: Ty): string {
		const vars = this.visible(t, false);
		if (vars.length > 0 && this.rng.chance(70)) {
			this.shape = Shape.Other;
			return vars[this.rng.below(vars.length)].name;
		}
		this.shape = Shape.Literal;
		return this.literal(t);
	}

	useHelper(name: string, text: string): string {
		for (const n of this.helperNames) { if (n == name) { return name; } }
		this.helperNames.push(name);
		this.helperText += text;
		return name;
	}

	arithHelper(op: string, t: Ty): string {
		const T = tyName(t);
		const Z = zero(t);
		const MIN = minLiteral(t);
		const MAX = maxLiteral(t);
		const head = "(a: " + T + ", b: " + T + "): " + T + " {\n";
		if (op == "+") {
			return this.useHelper("safeAdd" + tyTitle(t), "function safeAdd" + tyTitle(t) + head +
				"\tif (((b > " + Z + ") && (a > " + MAX + " - b)) || ((b < " + Z + ") && (a < " + MIN + " - b))) { return a; }\n" +
				"\treturn a + b;\n}\n");
		}
		if (op == "-") {
			return this.useHelper("safeSub" + tyTitle(t), "function safeSub" + tyTitle(t) + head +
				"\tif (((b < " + Z + ") && (a > " + MAX + " + b)) || ((b > " + Z + ") && (a < " + MIN + " + b))) { return a; }\n" +
				"\treturn a - b;\n}\n");
		}
		if (op == "*") {
			return this.useHelper("safeMul" + tyTitle(t), "function safeMul" + tyTitle(t) + head +
				"\tif (a > " + Z + ") {\n" +
				"\t\tif (b > " + Z + ") { if (a > " + MAX + " / b) { return a; } }\n" +
				"\t\telse { if (b < " + MIN + " / a) { return a; } }\n" +
				"\t} else {\n" +
				"\t\tif (b > " + Z + ") { if (a < " + MIN + " / b) { return a; } }\n" +
				"\t\telse { if (a != " + Z + " && b < " + MAX + " / a) { return a; } }\n" +
				"\t}\n" +
				"\treturn a * b;\n}\n");
		}
		const name = (op == "/" ? "safeDiv" : "safeMod") + tyTitle(t);
		const minusOne = trapsOnOverflow(t) ? " || (a == " + MIN + " && b == " + intLiteral(t, true, 1 as uint64) + ")" : "";
		return this.useHelper(name, "function " + name + head +
			"\tif (b == " + Z + minusOne + ") { return a; }\n" +
			"\treturn a " + op + " b;\n}\n");
	}

	negHelper(t: Ty): string {
		const T = tyName(t);
		return this.useHelper("safeNeg" + tyTitle(t), "function safeNeg" + tyTitle(t) + "(a: " + T + "): " + T + " {\n" +
			"\tif (a == " + minLiteral(t) + ") { return a; }\n" +
			"\treturn -a;\n}\n");
	}

	convHelper(from: Ty, to: Ty): string {
		const name = "conv" + tyTitle(from) + "To" + tyTitle(to);
		let inRange = "";
		if (isFloat(from)) {
			inRange = floatRangeTest(to);
		} else if (isSigned(from)) {
			inRange = "(x >= (" + minLiteral(to) + " as " + tyName(from) + ")) && (x <= (" + maxLiteral(to) + " as " + tyName(from) + "))";
		} else {
			inRange = "x <= (" + maxLiteral(to) + " as " + tyName(from) + ")";
		}
		return this.useHelper(name, "function " + name + "(x: " + tyName(from) + "): " + tyName(to) + " {\n" +
			"\tif (" + inRange + ") { return x as " + tyName(to) + "; }\n" +
			"\treturn " + zero(to) + ";\n}\n");
	}

	wrapHelper(from: Ty, to: Ty): string {
		const name = "wrap" + tyTitle(from) + "To" + tyTitle(to);
		return this.useHelper(name, "function " + name + "(x: " + tyName(from) + "): " + tyName(to) + " {\n" +
			"\treturn x as " + tyName(to) + ";\n}\n");
	}

	binary(t: Ty, depth: int32): string {
		const inElse = this.elseArms > 0;
		if (inElse) { this.arithInElse++; }
		const a = this.expr(t, depth + 1);
		const b = this.expr(t, depth + 1);
		if (inElse) { this.arithInElse--; }
		if (isFloat(t)) { return "(" + a + " " + this.pickOp(FLOAT_OPS) + " " + b + ")"; }
		const op = this.pickOp(INT_OPS);
		const guarded = op == "/" || op == "%" || (trapsOnOverflow(t) && (op == "+" || op == "-" || op == "*"));
		if (guarded) { return this.arithHelper(op, t) + "(" + a + ", " + b + ")"; }
		return "(" + a + " " + op + " " + b + ")";
	}

	binaryOrLeaf(t: Ty, depth: int32): string {
		return this.wt(W.ExprBinary) > 0 ? this.binary(t, depth) : this.leaf(t);
	}

	unary(t: Ty, depth: int32): string {
		const a = this.expr(t, depth + 1);
		if (isFloat(t)) { return "(-" + a + ")"; }
		if (!isSigned(t) || this.rng.chance(40)) { return "(~" + a + ")"; }
		return this.negHelper(t) + "(" + a + ")";
	}

	convert(t: Ty, depth: int32): string {
		if (this.tys.length < 2) { return this.binaryOrLeaf(t, depth); }
		const alternatives: Ty[] = [];
		for (const from of this.tys) { if (from != t) { alternatives.push(from); } }
		const from = alternatives[this.rng.below(alternatives.length)];
		const a = this.expr(from, depth + 1);
		const checkedAtCompileTime = this.shape != Shape.Other;
		if (checkedAtCompileTime && isSigned(from) && !isSigned(t) && !isFloat(t)) { return this.wrapHelper(from, t) + "(" + a + ")"; }
		if (fitsRaw(from, t)) { return "(" + a + " as " + tyName(t) + ")"; }
		return this.convHelper(from, t) + "(" + a + ")";
	}

	cond(depth: int32): string {
		if (this.nodesLeft == 0 || !this.reserve(1 as int64)) {
			const t = this.pickTy();
			return "(" + this.leaf(t) + " == " + this.leaf(t) + ")";
		}
		this.nodesLeft--;
		if (depth >= this.exprMax || this.rng.chance(60)) {
			const t = this.pickTy();
			const a = this.expr(t, depth + 1);
			const b = this.expr(t, depth + 1);
			return "(" + a + " " + this.pickOp(CMP_OPS) + " " + b + ")";
		}
		const k = this.rng.below(3);
		if (k == 0) { return "(!" + this.cond(depth + 1) + ")"; }
		const a = this.cond(depth + 1);
		const b = this.cond(depth + 1);
		return "(" + a + (k == 1 ? " && " : " || ") + b + ")";
	}

	call(t: Ty, depth: int32): string {
		const candidates: Fn[] = [];
		for (const f of this.fns) { if (f.ret == t) { candidates.push(f); } }
		if (candidates.length == 0) { return ""; }
		const f = candidates[this.rng.below(candidates.length)];
		if (!this.reserve(f.cost + (1 as int64))) { return ""; }
		let args = "";
		for (const p of f.params) {
			const a = this.expr(p, depth + 1);
			args = args == "" ? a : args + ", " + a;
		}
		return f.name + "(" + args + ")";
	}

	expr(t: Ty, depth: int32): string {
		if (this.nodesLeft == 0) { return this.leaf(t); }
		this.nodesLeft--;
		if (depth >= this.exprMax || !this.reserve(1 as int64)) { return this.leaf(t); }
		if (this.fams.length > 0 && this.rng.chance(this.wt(W.ExprFam))) {
			this.famShape = Shape.Other;
			const fam = this.famExpr(t, depth);
			if (fam != "" && !(this.famShape == Shape.Ternary && this.arithInElse > 0)) {
				this.shape = this.famShape;
				return fam;
			}
		}
		const kind = this.pickW(W.ExprLeaf, W.ExprCall);
		if (kind == 0) { return this.leaf(t); }
		let out = "";
		let shape = Shape.Other;
		if (kind == 1) {
			out = this.binary(t, depth);
		} else if (kind == 2) {
			out = this.unary(t, depth);
		} else if (kind == 3) {
			out = this.convert(t, depth);
		} else if (kind == 4) {
			if (this.arithInElse > 0) { return this.leaf(t); }
			out = "(" + this.cond(depth + 1) + " ? " + this.expr(t, depth + 1) + " : " + this.elseExpr(t, depth) + ")";
			shape = Shape.Ternary;
		} else {
			const c = this.call(t, depth);
			if (c == "" && this.wt(W.ExprBinary) == 0) { return this.leaf(t); }
			out = c != "" ? c : this.binary(t, depth);
		}
		this.shape = shape;
		return out;
	}

	has(f: Fam): boolean {
		for (const g of this.fams) { if (g == f) { return true; } }
		return false;
	}

	entsOf(kind: EntKind, t: Ty): Ent[] {
		const out: Ent[] = [];
		for (const e of this.ents) { if (e.kind == kind && e.ty == t) { out.push(e); } }
		return out;
	}

	entsAny(kind: EntKind): Ent[] {
		const out: Ent[] = [];
		for (const e of this.ents) { if (e.kind == kind) { out.push(e); } }
		return out;
	}

	pickEnt(ents: Ent[]): Ent { return ents[this.rng.below(ents.length)]; }

	elseExpr(t: Ty, depth: int32): string {
		this.elseArms++;
		const e = this.expr(t, depth + 1);
		this.elseArms--;
		return e;
	}

	ternary(text: string): string {
		this.famShape = Shape.Ternary;
		return text;
	}

	entName(prefix: string): string {
		const name = prefix + String(this.entCount);
		this.entCount = this.entCount + 1;
		return name;
	}

	args(params: Ty[], depth: int32): string {
		let out = "";
		for (const p of params) {
			const a = this.expr(p, depth + 1);
			out = out == "" ? a : out + ", " + a;
		}
		return out;
	}

	routine(t: Ty, depth: int32, cap: int64): Routine {
		const savedCost = this.cost;
		const savedCap = this.costCap;
		const savedMult = this.mult;
		this.cost = 0 as int64;
		this.costCap = cap;
		this.mult = 1 as int64;
		this.bodyDepth++;
		const text = this.expr(t, depth);
		this.bodyDepth--;
		const cost = this.cost;
		this.cost = savedCost;
		this.costCap = savedCap;
		this.mult = savedMult;
		return { text: text, cost: cost };
	}

	lambda(params: Ty[], ret: Ty, depth: int32, cap: int64): Routine {
		const saved = this.scope.length;
		let sig = "";
		for (const p of params) {
			const name = this.entName("q");
			this.scope.push({ name: name, ty: p, writable: false });
			sig = sig == "" ? name + ": " + tyName(p) : sig + ", " + name + ": " + tyName(p);
		}
		this.arrowDepth++;
		const body = this.routine(ret, depth + 1, cap);
		this.arrowDepth--;
		while (this.scope.length > saved) { this.scope.pop(); }
		return { text: "(" + sig + "): " + tyName(ret) + " => " + body.text, cost: body.cost };
	}

	smallInt(depth: int32): string {
		for (const t of this.tys) {
			if (t == Ty.Int32) { return this.expr(Ty.Int32, depth + 1); }
		}
		return String(this.rng.below(9));
	}

	famExpr(t: Ty, depth: int32): string {
		if (this.famTotal() == 0 || (this.clsBuilding > 0 && this.arrowDepth > 0)) { return ""; }
		const fam = this.pickFam();
		if (fam == Fam.Closure) { return this.closureExpr(t, depth); }
		if (fam == Fam.Union) { return this.unionExpr(t, depth); }
		if (fam == Fam.Agg) { return this.aggExpr(t, depth); }
		if (fam == Fam.Coll) { return this.collExpr(t, depth); }
		if (fam == Fam.Str) { return this.strExpr(t, depth); }
		if (fam == Fam.Own) { return this.ownExpr(t, depth); }
		if (fam == Fam.Iter) { return this.iterExpr(t, depth); }
		if (fam == Fam.Seq) { return this.seqExpr(t, depth); }
		if (fam == Fam.Gcls) { return this.gclsExpr(t, depth); }
		if (fam == Fam.Enum) { return this.enumExpr(t, depth); }
		if (fam == Fam.Exc) { return this.excExpr(t, depth); }
		if (fam == Fam.Native) { return this.nativeExpr(t, depth); }
		if (fam == Fam.Cls) { return this.clsExpr(t, depth); }
		if (fam == Fam.Conv) { return this.convExpr(t, depth); }
		return this.genericExpr(t, depth);
	}

	closureExpr(t: Ty, depth: int32): string {
		const k = this.pickW(W.ClosureNamed, W.ClosureIife);
		if (k == 0) {
			const named = this.entsOf(EntKind.Callable, t);
			if (named.length > 0) {
				const c = named[this.rng.below(named.length)];
				if (this.reserve(c.cost + (1 as int64))) { return c.name + "(" + this.args(c.params, depth) + ")"; }
			}
		}
		if (k == 1) {
			const arrays = this.entsOf(EntKind.ClosureArray, t);
			if (arrays.length > 0) {
				const a = arrays[this.rng.below(arrays.length)];
				if (this.reserve(a.cost + (1 as int64))) {
					return a.name + "[" + String(this.rng.below(a.len)) + "](" + this.expr(t, depth + 1) + ")";
				}
			}
		}
		if (this.wt(W.ClosureIife) == 0) { return ""; }
		const params: Ty[] = [];
		const n = this.rng.between(1, 2);
		for (let i = 0; i < n; i++) { params.push(this.pickTy()); }
		const f = this.lambda(params, t, depth, this.spare(1 as int64));
		if (!this.reserve(f.cost)) { return ""; }
		return "(" + f.text + ")(" + this.args(params, depth) + ")";
	}

	unionHelpers(t: Ty): string {
		const T = tyName(t);
		const U = T + " | string | null";
		this.useHelper("boxU" + tyTitle(t), "function boxU" + tyTitle(t) + "(k: int32, v: " + T + "): " + U + " {\n" +
			"\tconst r = k % 3;\n" +
			"\tif (r == 0) { return null; }\n" +
			"\tif (r == 1 || r == -1) { return \"s\" + String(v); }\n" +
			"\treturn v;\n}\n");
		this.useHelper("lenU" + tyTitle(t), "function lenU" + tyTitle(t) + "(u: " + U + "): int32 {\n" +
			"\tif (u === null) { return -1; }\n" +
			"\tif (typeof u === \"string\") { return u.length; }\n" +
			"\treturn 0;\n}\n");
		return this.useHelper("unboxU" + tyTitle(t), "function unboxU" + tyTitle(t) + "(u: " + U + ", d: " + T + "): " + T + " {\n" +
			"\tif (u === null) { return d; }\n" +
			"\tif (typeof u === \"string\") { return d; }\n" +
			"\treturn u;\n}\n");
	}

	unionExpr(t: Ty, depth: int32): string {
		if (t == Ty.Int32 && this.rng.chance(this.wt(W.UnionLen))) {
			const s = this.pickTy();
			this.unionHelpers(s);
			const vars = this.entsOf(EntKind.UnionVar, s);
			const u = vars.length > 0 && this.rng.chance(60)
				? vars[this.rng.below(vars.length)].name
				: "boxU" + tyTitle(s) + "(" + this.smallInt(depth) + ", " + this.expr(s, depth + 1) + ")";
			return "lenU" + tyTitle(s) + "(" + u + ")";
		}
		const unbox = this.unionHelpers(t);
		const vars = this.entsOf(EntKind.UnionVar, t);
		if (vars.length > 0 && this.rng.chance(60)) {
			return unbox + "(" + vars[this.rng.below(vars.length)].name + ", " + this.expr(t, depth + 1) + ")";
		}
		return unbox + "(boxU" + tyTitle(t) + "(" + this.smallInt(depth) + ", " + this.expr(t, depth + 1) + "), " + this.expr(t, depth + 1) + ")";
	}

	genericHelpers(): void {
		this.useHelper("idG", "function idG<T>(x: T): T { return x; }\n");
		this.useHelper("twiceG", "function twiceG<T>(f: (x: T) => T, x: T): T { return f(f(x)); }\n");
		this.useHelper("pickG", "function pickG<T>(xs: T[], i: int32, d: T): T { return i >= 0 && i < xs.length ? xs[i] : d; }\n");
		this.useHelper("BoxG", "class BoxG<T> {\n" +
			"\tv: T;\n" +
			"\tconstructor(v: T) { this.v = v; }\n" +
			"\tget(): T { return this.v; }\n" +
			"\tmap<U>(f: (x: T) => U): BoxG<U> { return new BoxG<U>(f(this.v)); }\n" +
			"}\n");
	}

	genericExpr(t: Ty, depth: int32): string {
		this.genericHelpers();
		const T = tyName(t);
		const k = this.pickW(W.GenericId, W.GenericBox);
		if (k == 0) { return "idG<" + T + ">(" + this.expr(t, depth + 1) + ")"; }
		if (k == 1) {
			const f = this.lambda([t], t, depth, this.spare(2 as int64));
			if (!this.reserve((2 as int64) * f.cost)) { return ""; }
			return "twiceG<" + T + ">(" + f.text + ", " + this.expr(t, depth + 1) + ")";
		}
		if (k == 2) {
			const n = this.rng.between(1, 3);
			let items = "";
			for (let i = 0; i < n; i++) {
				const e = this.expr(t, depth + 1);
				items = items == "" ? e : items + ", " + e;
			}
			return "pickG<" + T + ">([" + items + "], " + String(this.rng.below(n + 1)) + ", " + this.expr(t, depth + 1) + ")";
		}
		if (k == 3) {
			const s = this.pickTy();
			const f = this.lambda([s], t, depth, this.spare(1 as int64));
			if (!this.reserve(f.cost)) { return ""; }
			return "new BoxG<" + tyName(s) + ">(" + this.expr(s, depth + 1) + ").map<" + T + ">(" + f.text + ").get()";
		}
		const boxes = this.entsOf(EntKind.BoxVar, t);
		if (boxes.length > 0) { return boxes[this.rng.below(boxes.length)].name + ".get()"; }
		return "new BoxG<" + T + ">(" + this.expr(t, depth + 1) + ").get()";
	}

	aggHelpers(t: Ty): string {
		const T = tyName(t);
		const X = tyTitle(t);
		this.useHelper("InS" + X, "struct InS" + X + " { c: " + T + "; d: " + T + "; }\n" +
			"struct PtS" + X + " { a: " + T + "; n: InS" + X + "; }\n" +
			"function mkS" + X + "(a: " + T + ", c: " + T + ", d: " + T + "): PtS" + X + " { return { a: a, n: { c: c, d: d } }; }\n" +
			"function setS" + X + "(ref s: PtS" + X + ", x: " + T + "): void { s.n.d = s.a; s.a = x; }\n" +
			"function eqS" + X + "(s: PtS" + X + ", r: PtS" + X + ", x: " + T + ", y: " + T + "): " + T + " { return s == r ? x : y; }\n" +
			"class CellC" + X + " {\n" +
			"\tv: " + T + ";\n" +
			"\tp: PtS" + X + ";\n" +
			"\tconstructor(v: " + T + ") { this.v = v; this.p = mkS" + X + "(v, v, v); }\n" +
			"\tget(): " + T + " { return this.v; }\n" +
			"\tput(x: " + T + "): CellC" + X + " { this.p.n.c = this.v; this.v = x; return this; }\n" +
			"}\n");
		return X;
	}

	structField(): string { return [".a", ".n.c", ".n.d"][this.rng.below(3)]; }

	structValue(t: Ty, depth: int32): string {
		const vars = this.entsOf(EntKind.StructVar, t);
		if (vars.length > 0 && this.rng.chance(70)) { return vars[this.rng.below(vars.length)].name; }
		return "mkS" + tyTitle(t) + "(" + this.expr(t, depth + 1) + ", " + this.expr(t, depth + 1) + ", " + this.expr(t, depth + 1) + ")";
	}

	aggExpr(t: Ty, depth: int32): string {
		const X = this.aggHelpers(t);
		const structs = this.entsOf(EntKind.StructVar, t);
		const cells = this.entsOf(EntKind.ClassVar, t);
		const k = this.pickW(W.AggField, W.AggEq);
		if (k == 0) {
			if (structs.length > 0 && (cells.length == 0 || this.rng.chance(50))) {
				return structs[this.rng.below(structs.length)].name + this.structField();
			}
			if (cells.length > 0) {
				return cells[this.rng.below(cells.length)].name + (this.rng.chance(50) ? ".v" : ".p" + this.structField());
			}
		}
		if (k == 1) {
			const cell = cells.length > 0 ? cells[this.rng.below(cells.length)].name : "new CellC" + X + "(" + this.expr(t, depth + 1) + ")";
			if (this.rng.chance(50)) { return cell + ".get()"; }
			return cell + ".put(" + this.expr(t, depth + 1) + ").p" + this.structField();
		}
		if (k == 3 && !isFloat(t)) {
			return "eqS" + X + "(" + this.structValue(t, depth) + ", " + this.structValue(t, depth) + ", " + this.expr(t, depth + 1) + ", " + this.expr(t, depth + 1) + ")";
		}
		return this.structValue(t, depth) + this.structField();
	}

	aggStatement(t: Ty, indent: string): string {
		const X = this.aggHelpers(t);
		const structs = this.entsOf(EntKind.StructVar, t);
		const cells = this.entsOf(EntKind.ClassVar, t);
		const k = this.pickW(W.AggStruct, W.AggPoke);
		if (k >= 1 && k <= 3 && structs.length > 0) {
			const s = structs[this.rng.below(structs.length)].name;
			const other = structs[this.rng.below(structs.length)].name;
			if (k == 1) {
				const form = this.rng.below(3);
				if (form == 0) { return indent + s + " = " + other + ";\n"; }
				const name = this.entName("s");
				const value = form == 1 ? other : "{ ..." + other + ", a: " + this.expr(t, 0) + " }";
				this.ents.push({ kind: EntKind.StructVar, name: name, ty: t, params: [], len: 0, cost: 0 as int64 });
				return indent + "let " + name + ": PtS" + X + " = " + value + ";\n";
			}
			if (k == 2) {
				if (this.rng.chance(25)) { return indent + s + ".n = " + other + ".n;\n"; }
				return indent + s + this.structField() + " = " + this.expr(t, 0) + ";\n";
			}
			return indent + "setS" + X + "(" + s + ", " + this.expr(t, 0) + ");\n";
		}
		if (k >= 5 && cells.length > 0) {
			const c = cells[this.rng.below(cells.length)].name;
			if (k == 5) {
				const name = this.entName("k");
				this.ents.push({ kind: EntKind.ClassVar, name: name, ty: t, params: [], len: 0, cost: 0 as int64 });
				return indent + "const " + name + " = " + c + ";\n";
			}
			const form = this.rng.below(4);
			if (form == 0) { return indent + c + ".v = " + this.expr(t, 0) + ";\n"; }
			if (form == 1) { return indent + c + ".p" + this.structField() + " = " + this.expr(t, 0) + ";\n"; }
			if (form == 2) { return indent + c + ".p = " + this.structValue(t, 0) + ";\n"; }
			return indent + c + ".put(" + this.expr(t, 0) + ");\n";
		}
		if (k >= 4) {
			const name = this.entName("k");
			const text = indent + "const " + name + " = new CellC" + X + "(" + this.expr(t, 0) + ");\n";
			this.ents.push({ kind: EntKind.ClassVar, name: name, ty: t, params: [], len: 0, cost: 0 as int64 });
			return text;
		}
		const name = this.entName("s");
		const text = indent + "let " + name + ": PtS" + X + " = mkS" + X + "(" + this.expr(t, 0) + ", " + this.expr(t, 0) + ", " + this.expr(t, 0) + ");\n";
		this.ents.push({ kind: EntKind.StructVar, name: name, ty: t, params: [], len: 0, cost: 0 as int64 });
		return text;
	}

	collHelpers(t: Ty): string {
		const T = tyName(t);
		const X = tyTitle(t);
		this.useHelper("ixI", "function ixI(i: int32, n: int32): int32 { const r = i % n; return r < 0 ? r + n : r; }\n");
		this.useHelper("pushA" + X, "function pushA" + X + "(xs: " + T + "[], x: " + T + "): " + T + "[] { xs.push(x); return xs; }\n" +
			"function restA" + X + "(d: " + T + ", ...xs: " + T + "[]): " + T + " { return xs.length > 0 ? xs[xs.length - 1] : d; }\n");
		return X;
	}

	items(t: Ty, depth: int32, n: int32): string {
		let out = "";
		for (let i = 0; i < n; i++) {
			const e = this.expr(t, depth + 1);
			out = out == "" ? e : out + ", " + e;
		}
		return out;
	}

	collSize(t: Ty, depth: int32): string {
		if (t == Ty.Int32) {
			const arrays = this.entsAny(EntKind.ArrayVar);
			if (arrays.length == 0) { return ""; }
			const a = this.pickEnt(arrays);
			const form = this.rng.below(4);
			if (form == 1 && !isFloat(a.ty)) { return "(" + a.name + ".indexOf(" + this.expr(a.ty, depth + 1) + ") as int32)"; }
			if (form == 2) { return a.name + ".join(\",\").length"; }
			if (form == 3) { return a.name + ".concat(" + this.pickEnt(this.entsOf(EntKind.ArrayVar, a.ty)).name + ").length"; }
			return a.name + ".length";
		}
		if (isFloat(t)) { return ""; }
		const owners = this.entsOf(EntKind.ArrayVar, t).concat(this.entsOf(EntKind.SetVar, t));
		if (owners.length == 0) { return ""; }
		const o = this.pickEnt(owners);
		const test = o.kind == EntKind.SetVar ? ".has(" : ".includes(";
		const text = "(" + o.name + test + this.expr(t, depth + 1) + ") ? " + this.expr(t, depth + 1) + " : " + this.elseExpr(t, depth) + ")";
		return this.ternary(text);
	}

	collExpr(t: Ty, depth: int32): string {
		const X = this.collHelpers(t);
		const arrays = this.entsOf(EntKind.ArrayVar, t);
		const k = this.pickW(W.CollIndex, W.CollRest);
		if (k == 1) {
			const size = this.collSize(t, depth);
			if (size != "") { return size; }
		}
		if (k == 2) {
			const maps = this.entsOf(EntKind.MapVar, t);
			if (maps.length > 0) {
				const text = "(" + this.pickEnt(maps).name + ".get(" + this.smallInt(depth) + ") ?? " + this.elseExpr(t, depth) + ")";
				return this.ternary(text);
			}
		}
		if (k == 3) {
			const fixed = this.entsOf(EntKind.FixedVar, t);
			if (fixed.length > 0) {
				const f = this.pickEnt(fixed);
				return f.name + "[" + String(this.rng.below(f.len)) + "]";
			}
		}
		if (k == 4) {
			const d = this.expr(t, depth + 1);
			if (arrays.length > 0 && this.rng.chance(60)) { return "restA" + X + "(" + d + ", ..." + this.pickEnt(arrays).name + ")"; }
			const rest = this.items(t, depth, this.rng.below(3));
			return "restA" + X + "(" + d + (rest == "" ? "" : ", " + rest) + ")";
		}
		if (arrays.length > 0 && this.rng.chance(70)) {
			const a = this.pickEnt(arrays).name;
			const text = "(" + a + ".length > 0 ? " + a + "[ixI(" + this.smallInt(depth) + ", " + a + ".length)] : " + this.elseExpr(t, depth) + ")";
			return this.ternary(text);
		}
		const n = this.rng.between(1, 3);
		return "[" + this.items(t, depth, n) + "][" + String(this.rng.below(n)) + "]";
	}

	collLoop(t: Ty, a: string, indent: string): string {
		const trips = this.rng.between(1, 4);
		if (!this.reserve((2 * trips) as int64)) { return ""; }
		const init = this.expr(t, 0);
		const acc = this.newLocal(t);
		const j = this.entName("j");
		const maps = this.entsOf(EntKind.MapVar, t);
		const form = this.rng.below(maps.length > 0 ? 3 : 2);
		const saved = this.scope.length;
		const savedMult = this.mult;
		this.mult = this.mult * (trips as int64);
		let head = "";
		if (form == 1) {
			this.scope.push({ name: j, ty: Ty.Int32, writable: false });
			this.scope.push({ name: a + "[" + j + "]", ty: t, writable: false });
			head = "for (let " + j + ": int32 = 0; " + j + " < " + a + ".length && " + j + " < " + String(trips) + "; " + j + "++) {\n";
		} else if (form == 2) {
			const key = this.entName("x");
			const value = this.entName("x");
			this.scope.push({ name: key, ty: Ty.Int32, writable: false });
			this.scope.push({ name: value, ty: t, writable: false });
			head = "for (const [" + key + ", " + value + "] of " + this.pickEnt(maps).name + ") {\n";
		} else {
			const x = this.entName("x");
			this.scope.push({ name: x, ty: t, writable: false });
			head = "for (const " + x + " of " + a + ") {\n";
		}
		const body = this.expr(t, 1);
		this.mult = savedMult;
		while (this.scope.length > saved) { this.scope.pop(); }
		const tail = form == 1 ? "" : indent + "\t" + j + "++;\n" + indent + "\tif (" + j + " >= " + String(trips) + ") { break; }\n";
		return indent + "let " + acc + ": " + tyName(t) + " = " + init + ";\n" +
			(form == 1 ? "" : indent + "let " + j + ": int32 = 0;\n") +
			indent + head +
			indent + "\t" + acc + " = " + body + ";\n" +
			tail + indent + "}\n";
	}

	collStatement(t: Ty, indent: string): string {
		const X = this.collHelpers(t);
		const T = tyName(t);
		const arrays = this.entsOf(EntKind.ArrayVar, t);
		const k = this.pickW(W.CollDecl, W.CollFixed);
		if (k >= 1 && k <= 5 && arrays.length > 0) {
			const a = this.pickEnt(arrays).name;
			if (k == 1) {
				const value = this.rng.chance(50) ? a : "pushA" + X + "(" + a + ", " + this.expr(t, 0) + ")";
				const name = this.entName("a");
				this.ents.push({ kind: EntKind.ArrayVar, name: name, ty: t, params: [], len: 0, cost: 0 as int64 });
				return indent + "const " + name + " = " + value + ";\n";
			}
			if (k == 2) { return indent + a + ".push(" + this.expr(t, 0) + ");\n"; }
			if (k == 3) {
				const form = this.rng.below(6);
				const guard = indent + "if (" + a + ".length > 0) { ";
				if (form == 0) { return guard + a + "[ixI(" + this.smallInt(0) + ", " + a + ".length)] = " + this.expr(t, 0) + "; }\n"; }
				if (form == 1) { return guard + a + ".pop(); }\n"; }
				if (form == 2) { return guard + a + ".splice(ixI(" + this.smallInt(0) + ", " + a + ".length), 1); }\n"; }
				if (form == 3) {
					const n = String(this.rng.below(4));
					return indent + "if (" + a + ".length > " + n + ") { " + a + ".setLength(" + n + "); }\n";
				}
				if (form == 4) { return indent + a + ".fill(" + this.expr(t, 0) + ");\n"; }
				return indent + a + ".reverse();\n";
			}
			if (k == 4) { return this.collLoop(t, a, indent); }
			const n = this.rng.between(1, 3);
			let pattern = "";
			for (let i = 0; i < n; i++) {
				const slot = "l" + String(this.localCount + i) + " = " + this.expr(t, 0);
				pattern = pattern == "" ? slot : pattern + ", " + slot;
			}
			for (let i = 0; i < n; i++) { this.newLocal(t); }
			if (this.rng.chance(50)) { pattern += ", ..." + this.entName("r"); }
			return indent + "let [" + pattern + "] = " + a + ";\n";
		}
		if (k == 6) {
			const keyed = this.entsOf(EntKind.MapVar, t).concat(this.entsOf(EntKind.SetVar, t));
			if (keyed.length > 0 && this.rng.chance(60)) {
				const o = this.pickEnt(keyed);
				const drop = this.rng.chance(30);
				if (o.kind == EntKind.SetVar) { return indent + o.name + (drop ? ".delete(" : ".add(") + this.expr(t, 0) + ");\n"; }
				if (drop) { return indent + o.name + ".delete(" + this.smallInt(0) + ");\n"; }
				return indent + o.name + ".set(" + this.smallInt(0) + ", " + this.expr(t, 0) + ");\n";
			}
			if (isFloat(t) || this.rng.chance(50)) {
				const name = this.entName("m");
				const text = indent + "const " + name + " = new Map<int32, " + T + ">();\n" +
					indent + name + ".set(" + this.smallInt(0) + ", " + this.expr(t, 0) + ");\n";
				this.ents.push({ kind: EntKind.MapVar, name: name, ty: t, params: [], len: 0, cost: 0 as int64 });
				return text;
			}
			const name = this.entName("m");
			const text = indent + "const " + name + " = new Set<" + T + ">();\n" +
				indent + name + ".add(" + this.expr(t, 0) + ");\n";
			this.ents.push({ kind: EntKind.SetVar, name: name, ty: t, params: [], len: 0, cost: 0 as int64 });
			return text;
		}
		if (k == 7) {
			const fixed = this.entsOf(EntKind.FixedVar, t);
			if (fixed.length > 0 && this.rng.chance(60)) {
				const f = this.pickEnt(fixed);
				if (this.rng.chance(50)) { return indent + f.name + "[" + String(this.rng.below(f.len)) + "] = " + this.expr(t, 0) + ";\n"; }
				const name = this.entName("w");
				this.ents.push({ kind: EntKind.FixedVar, name: name, ty: t, params: [], len: f.len, cost: 0 as int64 });
				return indent + "let " + name + ": " + T + "[" + String(f.len) + "] = " + f.name + ";\n";
			}
			const n = this.rng.between(1, 4);
			const value = this.items(t, -1, n);
			const name = this.entName("w");
			this.ents.push({ kind: EntKind.FixedVar, name: name, ty: t, params: [], len: n, cost: 0 as int64 });
			return indent + "let " + name + ": " + T + "[" + String(n) + "] = [" + value + "];\n";
		}
		let value = "";
		const form = arrays.length > 0 ? this.rng.below(5) : 0;
		if (form == 1) {
			value = "[..." + this.pickEnt(arrays).name + ", " + this.expr(t, 0) + "]";
		} else if (form == 2) {
			value = this.pickEnt(arrays).name + ".concat(" + this.pickEnt(arrays).name + ")";
		} else if (form == 3) {
			const from = this.rng.below(3);
			value = this.pickEnt(arrays).name + ".slice(" + String(from) + (this.rng.chance(50) ? ", " + String(from + this.rng.below(4)) : "") + ")";
		} else if (form == 4) {
			const a = this.pickEnt(arrays).name;
			const trips = this.rng.between(1, 4);
			const f = this.lambda([t], t, 0, this.spare(trips as int64));
			if (!this.reserve((trips as int64) * f.cost)) { return ""; }
			value = a + ".slice(0, " + String(trips) + ").map(" + f.text + ")";
		} else {
			value = "[" + this.items(t, -1, this.rng.below(4)) + "]";
		}
		const name = this.entName("a");
		this.ents.push({ kind: EntKind.ArrayVar, name: name, ty: t, params: [], len: 0, cost: 0 as int64 });
		return indent + "let " + name + ": " + T + "[] = " + value + ";\n";
	}

	strLiteral(min: int32): string {
		let out = "";
		const n = this.rng.between(min, 4);
		for (let i = 0; i < n; i++) { out += STR_CHARS[this.rng.below(STR_CHARS.length)]; }
		return out;
	}

	strLeaf(): string {
		const vars = this.entsAny(EntKind.StrVar);
		if (vars.length > 0 && this.rng.chance(60)) { return this.pickEnt(vars).name; }
		return "\"" + this.strLiteral(0) + "\"";
	}

	strText(depth: int32): string {
		if (this.nodesLeft == 0 || depth >= this.exprMax || !this.reserve(1 as int64)) { return this.strLeaf(); }
		this.nodesLeft--;
		const k = this.pickW(W.StrConcat, W.StrEdit);
		if (k == 0) { return "(" + this.strText(depth + 1) + " + " + this.strText(depth + 1) + ")"; }
		if (k == 1) {
			const t = this.pickTy();
			if (this.rng.chance(50)) { return "String(" + this.expr(t, depth + 1) + ")"; }
			return "`" + this.strLiteral(0) + "${" + this.expr(t, depth + 1) + "}" + this.strLiteral(0) + "${" + this.strText(depth + 1) + "}`";
		}
		const s = "(" + this.strText(depth + 1) + ")";
		if (k == 2) {
			const form = this.rng.below(4);
			const from = String(this.rng.below(5));
			const to = String(this.rng.below(7));
			if (form == 0) { return s + ".slice(" + from + (this.rng.chance(50) ? ", " + to : "") + ")"; }
			if (form == 1) { return s + ".substring(" + from + ", " + to + ")"; }
			if (form == 2) { return s + ".charAt(" + String(this.rng.below(6)) + ")"; }
			this.useHelper("ixI", "function ixI(i: int32, n: int32): int32 { const r = i % n; return r < 0 ? r + n : r; }\n");
			const at = this.useHelper("atS", "function atS(s: string, i: int32): string { return s.length > 0 ? s[ixI(i, s.length)] : \"\"; }\n");
			return at + "(" + s + ", " + this.smallInt(depth) + ")";
		}
		if (k == 3) { return s + [".toUpperCase()", ".toLowerCase()", ".trim()", ".trimStart()", ".trimEnd()"][this.rng.below(5)]; }
		if (k == 4) {
			const form = this.rng.below(3);
			if (form == 0) { return s + ".repeat(" + String(this.rng.below(3)) + ")"; }
			const filled = "(" + s + " + \"" + this.strLiteral(1) + "\")";
			return filled + (form == 1 ? ".padStart(" : ".padEnd(") + String(this.rng.below(9)) + ", \"" + this.strLiteral(1) + "\")";
		}
		const form = this.rng.below(3);
		const search = "\"" + this.strLiteral(1) + "\"";
		if (form == 0) { return s + ".replace(" + search + ", \"" + this.strLiteral(0) + "\")"; }
		if (form == 1) { return s + ".replaceAll(" + search + ", \"" + this.strLiteral(0) + "\")"; }
		return s + ".split(" + search + ").join(\"" + this.strLiteral(0) + "\")";
	}

	strExpr(t: Ty, depth: int32): string {
		const k = this.pickW(W.StrSize, W.StrTest);
		if (t == Ty.Int32 && k == 0) {
			const s = "(" + this.strText(depth + 1) + ")";
			const form = this.rng.below(4);
			if (form == 0) { return s + ".length"; }
			if (form == 3) { return s + ".split(\"" + this.strLiteral(1) + "\").length"; }
			return "(" + s + (form == 1 ? ".indexOf(\"" : ".lastIndexOf(\"") + this.strLiteral(1) + "\") as int32)";
		}
		if (t == Ty.Int32 && k == 1) {
			this.useHelper("ixI", "function ixI(i: int32, n: int32): int32 { const r = i % n; return r < 0 ? r + n : r; }\n");
			const code = this.useHelper("codeS", "function codeS(s: string, i: int32): int32 { return s.length > 0 ? (s.charCodeAt(ixI(i, s.length)) as int32) : -1; }\n");
			return code + "(" + this.strText(depth + 1) + ", " + this.smallInt(depth) + ")";
		}
		const test = STR_TESTS[this.rng.below(STR_TESTS.length)];
		const left = this.strText(depth + 1);
		const a = left.startsWith("\"") ? "(" + left + " as string)" : left;
		const b = this.strText(depth + 1);
		const c = test.startsWith(".") ? "(" + a + ")" + test + b + ")" : "(" + a + test + b + ")";
		const text = "(" + c + " ? " + this.expr(t, depth + 1) + " : " + this.elseExpr(t, depth) + ")";
		return this.ternary(text);
	}

	strStatement(indent: string): string {
		const vars = this.entsAny(EntKind.StrVar);
		const k = this.pickW(W.StrDecl, W.StrAssign);
		if (k > 0 && vars.length > 0) {
			const v = this.pickEnt(vars).name;
			if (k == 1) { return indent + v + " += (" + this.strText(0) + ").slice(0, 8);\n"; }
			return indent + v + " = (" + this.strText(0) + ").slice(0, 32);\n";
		}
		const value = this.strText(0);
		const name = this.entName("s");
		this.ents.push({ kind: EntKind.StrVar, name: name, ty: Ty.Int32, params: [], len: 0, cost: 0 as int64 });
		return indent + "let " + name + ": string = " + value + ";\n";
	}

	ownHelpers(t: Ty): string {
		const T = tyName(t);
		const X = tyTitle(t);
		const O = "Own" + X;
		this.useHelper("ownHooks", "let ownHooks: int32 = 0;\n");
		this.useHelper("ixI", "function ixI(i: int32, n: int32): int32 { const r = i % n; return r < 0 ? r + n : r; }\n");
		this.useHelper(O, "struct " + O + " { v: " + T + "; tag: string; }\n" +
			"function onDestroy(this o: " + O + "): void { ownHooks = (ownHooks + 1) % 1000; }\n" +
			"function onCopy(this ref d: " + O + ", s: " + O + "): void { ownHooks = (ownHooks + 1) % 1000; d.v = s.v; d.tag = s.tag; }\n" +
			"function mkO" + X + "(v: " + T + ", t: string): " + O + " { return { v: v, tag: t }; }\n" +
			"function takeO" + X + "(o: " + O + "): " + T + " { return o.v; }\n" +
			"function bumpO" + X + "(ref o: " + O + ", x: " + T + "): void { o.v = x; o.tag = o.tag.slice(0, 4) + \"+\"; }\n" +
			"function fillO" + X + "(out o: " + O + ", x: " + T + "): void { o = mkO" + X + "(x, \"o\"); }\n");
		return X;
	}

	ownExpr(t: Ty, depth: int32): string {
		if (this.bodyDepth > 0) { return ""; }
		const owns = this.entsOf(EntKind.OwnVar, t);
		const held = this.entsOf(EntKind.HeldVar, t);
		const k = this.pickW(W.OwnField, W.OwnHeld);
		if (k == 1 && held.length > 0) {
			const h = this.pickEnt(held).name;
			const text = "(" + h + ".length > 0 ? " + h + "[ixI(" + this.smallInt(depth) + ", " + h + ".length)].v : " + this.elseExpr(t, depth) + ")";
			return this.ternary(text);
		}
		if (owns.length == 0) { return ""; }
		const o = this.pickEnt(owns).name;
		return t == Ty.Int32 && this.rng.chance(30) ? o + ".tag.length" : o + ".v";
	}

	dropEnt(name: string): void {
		for (let i = 0; i < this.ents.length; i++) {
			if (this.ents[i].name == name) {
				this.ents.splice(i, 1);
				return;
			}
		}
	}

	ownStatement(t: Ty, indent: string): string {
		const X = this.ownHelpers(t);
		const O = "Own" + X;
		const owns = this.entsOf(EntKind.OwnVar, t);
		const held = this.entsOf(EntKind.HeldVar, t);
		const k = this.pickW(W.OwnDecl, W.OwnSink);
		if (k >= 1 && owns.length > 0) {
			const o = this.pickEnt(owns).name;
			if (k == 1) {
				const other = this.pickEnt(owns).name;
				if (other != o && this.rng.chance(50)) { return indent + o + " = " + other + ";\n"; }
				const name = this.entName("o");
				this.ents.push({ kind: EntKind.OwnVar, name: name, ty: t, params: [], len: this.blockId, cost: 0 as int64 });
				return indent + "let " + name + ": " + O + " = " + o + ";\n";
			}
			if (k == 2) {
				const movable: Ent[] = [];
				for (const e of owns) { if (e.len == this.blockId) { movable.push(e); } }
				if (movable.length > 0) {
					const m = this.pickEnt(movable).name;
					this.dropEnt(m);
					const form = this.rng.below(held.length > 0 ? 3 : 2);
					if (form == 2) { return indent + this.pickEnt(held).name + ".push(move " + m + ");\n"; }
					if (form == 1) { return indent + "let " + this.newLocal(t) + ": " + tyName(t) + " = takeO" + X + "(move " + m + ");\n"; }
					const name = this.entName("o");
					this.ents.push({ kind: EntKind.OwnVar, name: name, ty: t, params: [], len: this.blockId, cost: 0 as int64 });
					return indent + "let " + name + ": " + O + " = move " + m + ";\n";
				}
			}
			if (k == 3) { return indent + "bumpO" + X + "(" + o + ", " + this.expr(t, 0) + ");\n"; }
			if (k == 4) { return indent + "fillO" + X + "(out " + o + ", " + this.expr(t, 0) + ");\n"; }
			if (k == 5) {
				if (held.length > 0 && this.rng.chance(50)) { return indent + this.pickEnt(held).name + ".push(" + o + ");\n"; }
				const value = "[" + o + ", mkO" + X + "(" + this.expr(t, 0) + ", \"h\")]";
				const name = this.entName("h");
				this.ents.push({ kind: EntKind.HeldVar, name: name, ty: t, params: [], len: 0, cost: 0 as int64 });
				return indent + "let " + name + ": " + O + "[] = " + value + ";\n";
			}
		}
		const value = "mkO" + X + "(" + this.expr(t, 0) + ", \"" + this.strLiteral(0) + "\")";
		const name = this.entName("o");
		this.ents.push({ kind: EntKind.OwnVar, name: name, ty: t, params: [], len: this.blockId, cost: 0 as int64 });
		return indent + "let " + name + ": " + O + " = " + value + ";\n";
	}

	hasTy(t: Ty): boolean {
		for (const x of this.tys) { if (x == t) { return true; } }
		return false;
	}

	cvSeal(text: string, shape: Shape): string {
		this.famShape = shape;
		return text;
	}

	cvOp(op: string, t: Ty, a: string, b: string): string {
		if (isFloat(t) || !trapsOnOverflow(t)) { return "(" + a + " " + op + " " + b + ")"; }
		return this.arithHelper(op, t) + "(" + a + ", " + b + ")";
	}

	cvCore(t: Ty): void {
		const T = tyName(t);
		const X = tyTitle(t);
		const S = "CvS" + X;
		const C = "CvC" + X;
		this.useHelper("cvCore" + X,
			"struct " + S + " { v: " + T + "; w: " + T + "; }\n" +
			"type CvA" + X + " = " + S + ";\n" +
			"class " + C + " {\n" +
			"\tv: " + T + ";\n" +
			"\tw: " + T + ";\n" +
			"\tconstructor(v: " + T + ", w: " + T + ") { this.v = v; this.w = w; }\n" +
			"}\n" +
			"function cvOf(this typeof " + S + ", v: " + T + ", w: " + T + "): " + S + " { return { v: v, w: w }; }\n" +
			"function cvOf(this typeof " + C + ", v: " + T + ", w: " + T + "): " + C + " { return new " + C + "(v, w); }\n" +
			"function cvZero(this typeof " + S + "): " + T + " { return " + zero(t) + "; }\n" +
			"function cvSum(this s: " + S + "): " + T + " { return " + this.cvOp("+", t, "s.v", "s.w") + "; }\n" +
			"function cvSum(this c: " + C + "): " + T + " { return " + this.cvOp("+", t, "c.v", "c.w") + "; }\n" +
			"function cvStep(this x: " + T + ", k: " + T + "): " + T + " { return " + this.cvOp("+", t, "x", "k") + "; }\n" +
			"function cvBump(this ref n: " + T + ", k: " + T + "): void { n = " + this.cvOp("-", t, "n", "k") + "; }\n" +
			"function cvShift(this ref s: " + S + ", k: " + T + "): void { s.v = " + this.cvOp("+", t, "s.v", "k") + "; s.w = " + this.cvOp("-", t, "s.w", "k") + "; }\n" +
			"function cvSwap(this ref s: " + S + "): void { const t = s.v; s.v = s.w; s.w = t; }\n" +
			"function cvShift(this c: " + C + ", k: " + T + "): " + C + " { c.v = " + this.cvOp("+", t, "c.v", "k") + "; return c; }\n" +
			"function cvPick(this s: string, a: " + T + ", b: " + T + "): " + T + " { return s.length > 2 ? a : b; }\n");
	}

	cvItems(t: Ty): void {
		this.cvCore(t);
		const T = tyName(t);
		const X = tyTitle(t);
		const S = "CvS" + X;
		this.useHelper("cvItems" + X,
			"function toItems(this s: " + S + "): " + T + "[] { return [s.v, s.w, " + this.cvOp("+", t, "s.v", "s.w") + "]; }\n" +
			"function cvFoldS" + X + "(s: " + S + ", d: " + T + "): " + T + " {\n" +
			"\tlet r: " + T + " = d;\n" +
			"\tfor (const x of s) { r = " + this.cvOp("-", t, "x", "r") + "; }\n" +
			"\treturn r;\n}\n");
	}

	cvItemsClass(t: Ty): boolean {
		const name = "cvItemsC" + tyTitle(t);
		for (const n of this.helperNames) { if (n.startsWith("cvItemsC") && n != name) { return false; } }
		this.cvCore(t);
		const T = tyName(t);
		const X = tyTitle(t);
		const C = "CvC" + X;
		this.useHelper(name,
			"function* toItems(this c: " + C + "): Iterator<" + T + "> { yield c.v; yield c.w; }\n" +
			"function cvFoldC" + X + "(c: " + C + ", d: " + T + "): " + T + " {\n" +
			"\tlet r: " + T + " = d;\n" +
			"\tfor (const x of c) { r = " + this.cvOp("+", t, "x", "r") + "; }\n" +
			"\treturn r;\n}\n");
		return true;
	}

	cvText(t: Ty): void {
		this.cvCore(t);
		const X = tyTitle(t);
		this.useHelper("cvText" + X, "function toString(this s: CvS" + X + "): string { return String(s.v) + \"|\" + String(s.w); }\n");
	}

	cvProto(t: Ty): void {
		const T = tyName(t);
		const X = tyTitle(t);
		this.useHelper("cvProto" + X,
			"struct CvV" + X + " { v: " + T + "; }\n" +
			"struct CvK" + X + " { v: " + T + "; }\n" +
			"struct CvD" + X + " { v: " + T + "; }\n" +
			"function valueOf(this s: CvV" + X + "): " + T + " { return s.v; }\n" +
			"converter cvConv" + X + "(k: CvK" + X + "): " + T + " { return k.v; }\n" +
			"function getDynamicField(this d: CvD" + X + ", key: string): " + T + " { return " + this.cvOp("+", t, "d.v", "(key.length as " + T + ")") + "; }\n" +
			"function cvTake" + X + "(x: " + T + "): " + T + " { return x; }\n" +
			"function cvMkV" + X + "(x: " + T + "): CvV" + X + " { return { v: x }; }\n" +
			"function cvMkK" + X + "(x: " + T + "): CvK" + X + " { return { v: x }; }\n" +
			"function cvMkD" + X + "(x: " + T + "): CvD" + X + " { return { v: x }; }\n");
	}

	cvOps(t: Ty): void {
		this.cvCore(t);
		const T = tyName(t);
		const X = tyTitle(t);
		const S = "CvS" + X;
		let text = "function `+`(this a: " + S + ", b: " + S + "): " + S + " { return { v: " + this.cvOp("+", t, "a.v", "b.v") + ", w: " + this.cvOp("+", t, "a.w", "b.w") + " }; }\n" +
			"function `-`(this a: " + S + ", b: " + S + "): " + S + " { return { v: " + this.cvOp("-", t, "a.v", "b.v") + ", w: " + this.cvOp("-", t, "a.w", "b.w") + " }; }\n" +
			"function `-`(this a: " + S + "): " + S + " { return { v: " + this.cvOp("-", t, zero(t), "a.v") + ", w: " + this.cvOp("-", t, zero(t), "a.w") + " }; }\n" +
			"function `<`(this a: " + S + ", b: " + S + "): boolean { return a.v < b.v; }\n" +
			"function `==`(this a: " + S + ", b: " + S + "): boolean { return a.v == b.v && a.w == b.w; }\n" +
			"function `**`(this a: " + T + ", b: " + T + "): " + T + " { return " + this.cvOp("-", t, this.cvOp("+", t, "a", "a"), "b") + "; }\n" +
			"function `**=`(this ref a: " + T + ", b: " + T + "): void { a = " + this.cvOp("-", t, "b", "a") + "; }\n";
		if (!isFloat(t)) {
			text += "function `*`(this a: " + S + ", k: " + T + "): " + S + " { return { v: " + this.cvOp("*", t, "a.v", "k") + ", w: " + this.cvOp("*", t, "a.w", "k") + " }; }\n" +
				"function `*`(this k: " + T + ", a: " + S + "): " + S + " { return { v: " + this.cvOp("*", t, "k", "a.v") + ", w: " + this.cvOp("*", t, "k", "a.w") + " }; }\n";
		}
		this.useHelper("cvOps" + X, text);
	}

	cvRun(t: Ty, variant: int32): string {
		this.cvCore(t);
		const T = tyName(t);
		const X = tyTitle(t);
		const S = "CvS" + X;
		const C = "CvC" + X;
		const name = "cvRun" + String(variant) + X;
		let body = "";
		if (variant == 0) {
			body = "\tlet s: " + S + " = { v: a, w: b };\n\ts.cvShift(k);\n\ts.cvSwap();\n\treturn s.cvSum();\n";
		} else if (variant == 1) {
			body = "\tlet s: " + S + " = { v: a, w: b };\n\tlet q: " + S + " = s;\n\tq.cvShift(k);\n\treturn " + this.cvOp("+", t, "s.cvSum()", "q.v") + ";\n";
		} else if (variant == 2) {
			body = "\tlet n: " + T + " = a;\n\tn.cvBump(k);\n\tn.cvBump(b);\n\treturn n;\n";
		} else if (variant == 3) {
			body = "\tconst xs: " + T + "[] = [a, b];\n\txs[1].cvBump(k);\n\txs[0].cvBump(xs[1]);\n\treturn xs[0];\n";
		} else if (variant == 4) {
			body = "\tlet s: " + S + " = { v: a, w: b };\n\ts.v.cvBump(k);\n\ts.w.cvBump(s.v);\n\treturn s.cvSum();\n";
		} else {
			body = "\tconst c = " + C + ".cvOf(a, b);\n\tc.v.cvBump(k);\n\tc.cvShift(k);\n\treturn c.cvSum();\n";
		}
		return this.useHelper(name, "function " + name + "(a: " + T + ", b: " + T + ", k: " + T + "): " + T + " {\n" + body + "}\n");
	}

	cvArg(t: Ty, depth: int32): string {
		const text = this.expr(t, depth + 1);
		return this.shape == Shape.Ternary ? this.leaf(t) : text;
	}

	cvRefArg(t: Ty): string { return this.leaf(t); }

	cvInt32To(text: string, t: Ty): string {
		if (t == Ty.Int32) { return text; }
		if (fitsRaw(Ty.Int32, t)) { return "(" + text + " as " + tyName(t) + ")"; }
		return this.convHelper(Ty.Int32, t) + "(" + text + ")";
	}

	cvInt64To(text: string, t: Ty): string {
		if (t == Ty.Int64) { return text; }
		if (fitsRaw(Ty.Int64, t)) { return "(" + text + " as " + tyName(t) + ")"; }
		return this.convHelper(Ty.Int64, t) + "(" + text + ")";
	}

	cvStruct(t: Ty, depth: int32): string {
		const vars = this.entsOf(EntKind.ConvS, t);
		if (vars.length > 0 && this.rng.chance(60)) { return this.pickEnt(vars).name; }
		return "CvS" + tyTitle(t) + ".cvOf(" + this.expr(t, depth + 1) + ", " + this.expr(t, depth + 1) + ")";
	}

	cvViaClass(t: Ty, kind: int32, depth: int32): string {
		const T = tyName(t);
		const X = tyTitle(t);
		const name = "cvVia" + String(kind) + X;
		const wide = kind == 3;
		const params = "a: " + T + ", b: " + T + (wide ? ", c: " + T + ", d: " + T : "");
		const tails = [".cvSum()", ".v", ".w", ".cvShift(c).cvShift(d).cvSum()"];
		this.useHelper(name, "function " + name + "(" + params + "): " + T + " {\n\treturn CvC" + X + ".cvOf(a, b)" + tails[kind] + ";\n}\n");
		const a = this.expr(t, depth + 1);
		const b = this.expr(t, depth + 1);
		if (!wide) { return name + "(" + a + ", " + b + ")"; }
		const c = this.expr(t, depth + 1);
		const d = this.expr(t, depth + 1);
		return name + "(" + a + ", " + b + ", " + c + ", " + d + ")";
	}

	convExpr(t: Ty, depth: int32): string {
		const k = this.pickW(W.ConvCast, W.ConvOp);
		if (k == 0) { return this.convCast(t, depth); }
		if (k == 1) { return this.convFrac(t, depth); }
		if (k == 2) { return this.convText(t, depth); }
		if (k == 3) { return this.convExt(t, depth); }
		if (k == 4) { return this.convRef(t, depth); }
		if (k == 5) { return this.convStatic(t, depth); }
		if (k == 6) { return this.convProto(t, depth); }
		return this.convOp(t, depth);
	}

	convCast(t: Ty, depth: int32): string {
		if (this.tys.length < 2) { return ""; }
		const steps = this.rng.between(2, 3);
		const path: Ty[] = [t];
		for (let i = 0; i < steps; i++) {
			const alternatives: Ty[] = [];
			for (const x of this.tys) { if (x != path[i]) { alternatives.push(x); } }
			path.push(alternatives[this.rng.below(alternatives.length)]);
		}
		let text = this.expr(path[steps], depth + 1);
		let constant = this.shape != Shape.Other;
		for (let j = steps - 1; j >= 0; j--) {
			const from = path[j + 1];
			const to = path[j];
			if (constant && isSigned(from) && !isSigned(to) && !isFloat(to)) {
				text = this.wrapHelper(from, to) + "(" + text + ")";
				constant = false;
			} else if (fitsRaw(from, to)) {
				text = "(" + text + " as " + tyName(to) + ")";
			} else {
				text = this.convHelper(from, to) + "(" + text + ")";
				constant = false;
			}
		}
		return this.cvSeal(text, constant ? Shape.Literal : Shape.Other);
	}

	convFrac(t: Ty, depth: int32): string {
		if (isFloat(t)) { return ""; }
		if (this.rng.chance(25)) {
			const negative = isSigned(t) && this.rng.chance(50);
			const magnitude = String(this.rng.below(101)) + "." + ["25", "5", "75", "99", "01"][this.rng.below(5)];
			return this.cvSeal("(" + (negative ? "(-" + magnitude + ")" : magnitude) + " as " + tyName(t) + ")", Shape.Literal);
		}
		const exact: Ty[] = [];
		for (const s of this.tys) { if (!isFloat(s) && bitsOf(s) <= 32) { exact.push(s); } }
		const floats = this.hasTy(Ty.Float64);
		if (exact.length == 0 && !floats) { return ""; }
		if (!this.reserve(4 as int64)) { return ""; }
		let source = "";
		if (exact.length > 0 && (!floats || this.rng.chance(70))) {
			const s = exact[this.rng.below(exact.length)];
			const base = "(" + this.expr(s, depth + 1) + " as float64)";
			const scaled = this.rng.chance(50) ? "(" + base + " / " + ["2.0", "4.0", "8.0"][this.rng.below(3)] + ")" : base;
			source = "(" + scaled + (this.rng.chance(50) ? " + " : " - ") + ["0.25", "0.5", "0.75", "1.5", "2.5"][this.rng.below(5)] + ")";
		} else {
			source = this.expr(Ty.Float64, depth + 1);
		}
		return this.cvSeal(this.convHelper(Ty.Float64, t) + "(" + source + ")", Shape.Other);
	}

	convText(t: Ty, depth: int32): string {
		if (!this.reserve(4 as int64)) { return ""; }
		const ints = this.intTys();
		const parseable: Ty[] = [];
		for (const s of ints) { if (s != Ty.Uint64) { parseable.push(s); } }
		const hasFloat = this.hasTy(Ty.Float64);
		let text = "";
		if (isFloat(t)) {
			const form = this.rng.below(ints.length > 0 ? 6 : 4);
			if (form < 4) {
				const f = this.expr(t, depth + 1);
				if (form == 0) { text = "(parseFloat(String(" + f + ")) as float64)"; }
				else if (form == 1) { text = "(Number(String(" + f + ")) as float64)"; }
				else if (form == 2) { text = "(String(" + f + ").parseFloat() as float64)"; }
				else { text = "(Number((" + f + ").toString()) as float64)"; }
			} else {
				const s = ints[this.rng.below(ints.length)];
				const i = this.expr(s, depth + 1);
				if (form == 4) { text = "(Number(" + i + ") as float64)"; }
				else if (this.rng.chance(50)) { text = "(Number(String(" + i + ")) as float64)"; }
				else { text = "(String(" + i + ").parseFloat() as float64)"; }
			}
			return this.cvSeal(text, Shape.Other);
		}
		const form = this.rng.below(4);
		if (form == 0 && parseable.length > 0 && t != Ty.Uint64) {
			const s = parseable[this.rng.below(parseable.length)];
			const i = this.expr(s, depth + 1);
			const k = this.rng.below(3);
			const parsed = k == 0 ? "parseInt(String(" + i + "))" : k == 1 ? "String(" + i + ").parseInt()" : "(" + i + ").toString().parseInt()";
			text = this.cvInt64To(parsed, t);
		} else if (form == 1 || (form == 0 && t == Ty.Uint64)) {
			const s = this.pickTy();
			const x = this.expr(s, depth + 1);
			let shown = "String(" + x + ")";
			if (!isFloat(s) && this.rng.chance(50)) { shown = "(" + x + ").toString(" + String([2, 8, 16, 36][this.rng.below(4)]) + ")"; }
			text = this.cvInt32To(shown + ".length", t);
		} else if (ints.length > 0) {
			const s = ints[this.rng.below(ints.length)];
			const i = this.expr(s, depth + 1);
			text = this.convHelper(Ty.Float64, t) + "(" + (this.rng.chance(50) ? "(Number(" + i + ") as float64)" : "(Number(String(" + i + ")) as float64)") + ")";
		} else if (hasFloat) {
			text = this.convHelper(Ty.Float64, t) + "((parseFloat(String(" + this.expr(Ty.Float64, depth + 1) + ")) as float64))";
		} else {
			return "";
		}
		return this.cvSeal(text, Shape.Other);
	}

	convExt(t: Ty, depth: int32): string {
		if (!this.reserve(4 as int64)) { return ""; }
		this.cvCore(t);
		const form = this.rng.below(5);
		let text = "";
		if (form == 0) {
			text = "(" + this.expr(t, depth + 1) + ").cvStep(" + this.cvArg(t, depth) + ")";
			if (this.rng.chance(40)) { text += ".cvStep(" + this.cvArg(t, depth) + ")"; }
		} else if (form == 1) {
			const s = this.strText(depth + 1);
			text = (s.startsWith("\"") ? "(" + s + " as string)" : "(" + s + ")") + ".cvPick(" + this.cvArg(t, depth) + ", " + this.cvArg(t, depth) + ")";
		} else if (form == 2) {
			text = this.cvStruct(t, depth) + ".cvSum()";
		} else if (form == 3) {
			text = this.cvViaClass(t, this.rng.below(3), depth);
		} else {
			text = this.cvViaClass(t, 3, depth);
		}
		return this.cvSeal(text, Shape.Other);
	}

	convRef(t: Ty, depth: int32): string {
		if (!this.reserve(8 as int64)) { return ""; }
		const name = this.cvRun(t, this.rng.below(6));
		return this.cvSeal(name + "(" + this.expr(t, depth + 1) + ", " + this.expr(t, depth + 1) + ", " + this.expr(t, depth + 1) + ")", Shape.Other);
	}

	convStatic(t: Ty, depth: int32): string {
		if (!this.reserve(4 as int64)) { return ""; }
		this.cvCore(t);
		const X = tyTitle(t);
		const form = this.rng.below(4);
		let text = "";
		if (form == 3) {
			const inElse = this.elseArms > 0;
			if (inElse) { this.arithInElse++; }
			text = this.cvOp("+", t, "CvS" + X + ".cvZero()", this.expr(t, depth + 1));
			if (inElse) { this.arithInElse--; }
			return this.cvSeal(text, Shape.Other);
		}
		if (form == 1) { return this.cvSeal(this.cvViaClass(t, this.rng.chance(50) ? 0 : 2, depth), Shape.Other); }
		const a = this.expr(t, depth + 1);
		const b = this.expr(t, depth + 1);
		if (form == 0) {
			text = "CvS" + X + ".cvOf(" + a + ", " + b + ")" + (this.rng.chance(50) ? ".cvSum()" : ".v");
		} else {
			text = "CvA" + X + ".cvOf(" + a + ", " + b + ").w";
		}
		return this.cvSeal(text, Shape.Other);
	}

	convProto(t: Ty, depth: int32): string {
		if (!this.reserve(6 as int64)) { return ""; }
		this.cvCore(t);
		const X = tyTitle(t);
		const form = this.rng.below(6);
		let text = "";
		if (form == 0) {
			this.cvText(t);
			const shown = this.cvStruct(t, depth);
			const name = this.rng.chance(50) ? "String(" + shown + ")" : shown + ".toString()";
			if (isFloat(t)) { text = "(" + name + ".parseFloat() as float64)"; }
			else if (t == Ty.Uint64) { text = this.cvInt32To(name + ".length", t); }
			else { text = this.cvInt64To(name + ".parseInt()", t); }
		} else if (form == 1) {
			this.cvItems(t);
			const d = this.expr(t, depth + 1);
			const held = this.entsOf(EntKind.ConvC, t);
			if (held.length > 0 && this.rng.chance(50) && this.cvItemsClass(t)) {
				text = "cvFoldC" + X + "(" + this.pickEnt(held).name + ", " + d + ")";
			} else {
				text = "cvFoldS" + X + "(" + this.cvStruct(t, depth) + ", " + d + ")";
			}
		} else if (form == 2) {
			this.cvProto(t);
			const made = "cvMkV" + X + "(" + this.expr(t, depth + 1) + ")";
			text = this.rng.chance(50) ? "cvTake" + X + "(" + made + ")" : "(" + made + " as " + tyName(t) + ")";
		} else if (form == 3) {
			this.cvProto(t);
			const made = "cvMkK" + X + "(" + this.expr(t, depth + 1) + ")";
			text = this.rng.chance(50) ? "cvTake" + X + "(" + made + ")" : "(" + made + " as " + tyName(t) + ")";
		} else {
			this.cvProto(t);
			text = "cvMkD" + X + "(" + this.expr(t, depth + 1) + ")." + ["p", "qq", "rrr", "ssss", "ttttt"][this.rng.below(5)];
		}
		return this.cvSeal(text, Shape.Other);
	}

	convOp(t: Ty, depth: int32): string {
		if (!this.reserve(5 as int64)) { return ""; }
		this.cvOps(t);
		const form = this.rng.below(isFloat(t) ? 5 : 6);
		if (form == 3) {
			const left = this.cvStruct(t, depth);
			const right = this.cvStruct(t, depth);
			const text = "(" + left + (this.rng.chance(50) ? " < " : " == ") + right + " ? " + this.expr(t, depth + 1) + " : " + this.elseExpr(t, depth) + ")";
			return this.ternary(text);
		}
		const inElse = this.elseArms > 0;
		if (inElse) { this.arithInElse++; }
		const text = this.cvOpText(t, depth, form);
		if (inElse) { this.arithInElse--; }
		return this.cvSeal(text, Shape.Other);
	}

	cvOpText(t: Ty, depth: int32, form: int32): string {
		const field = this.rng.chance(50) ? ".v" : ".w";
		if (form == 4) {
			const a = this.expr(t, depth + 1);
			return "(" + a + " ** " + this.expr(t, depth + 1) + ")";
		}
		const left = this.cvStruct(t, depth);
		if (form == 5) {
			const k = this.expr(t, depth + 1);
			return this.rng.chance(50) ? "(" + left + " * " + k + ")" + field : "(" + k + " * " + left + ")" + field;
		}
		const right = this.cvStruct(t, depth);
		if (form == 0) { return "(" + left + " + " + right + ")" + field; }
		if (form == 1) { return "(" + left + " - " + right + ")" + field; }
		return "((-" + left + ") + " + right + ")" + field;
	}

	cvDeclStruct(t: Ty, indent: string, viaStatic: boolean): string {
		const X = tyTitle(t);
		const structs = this.entsOf(EntKind.ConvS, t);
		let value = "";
		if (structs.length > 0 && this.rng.chance(30)) {
			value = this.pickEnt(structs).name;
		} else if (viaStatic) {
			value = "CvS" + X + ".cvOf(" + this.expr(t, 0) + ", " + this.expr(t, 0) + ")";
		} else {
			value = "{ v: " + this.expr(t, 0) + ", w: " + this.expr(t, 0) + " }";
		}
		const name = this.entName("z");
		this.ents.push({ kind: EntKind.ConvS, name: name, ty: t, params: [], len: 0, cost: 0 as int64 });
		return indent + "let " + name + ": CvS" + X + " = " + value + ";\n";
	}

	cvDeclObject(t: Ty, indent: string, viaStatic: boolean): string {
		const X = tyTitle(t);
		const objects = this.entsOf(EntKind.ConvC, t);
		let value = "";
		if (objects.length > 0 && this.rng.chance(30)) {
			value = this.pickEnt(objects).name;
		} else if (viaStatic) {
			value = "CvC" + X + ".cvOf(" + this.expr(t, 0) + ", " + this.expr(t, 0) + ")";
		} else {
			value = "new CvC" + X + "(" + this.expr(t, 0) + ", " + this.expr(t, 0) + ")";
		}
		const name = this.entName("v");
		this.ents.push({ kind: EntKind.ConvC, name: name, ty: t, params: [], len: 0, cost: 0 as int64 });
		return indent + "const " + name + " = " + value + ";\n";
	}

	convStatement(t: Ty, indent: string): string {
		const k = this.pickW(W.ConvCast, W.ConvOp);
		if (k < 3 || !this.reserve(6 as int64)) { return ""; }
		this.cvCore(t);
		if (k == 3 || k == 5) {
			if (this.rng.chance(60)) { return this.cvDeclStruct(t, indent, k == 5); }
			return this.cvDeclObject(t, indent, k == 5);
		}
		if (k == 4) { return this.cvRefStatement(t, indent); }
		if (k == 6) { return this.cvDrain(t, indent); }
		return this.cvOpStatement(t, indent);
	}

	cvRefStatement(t: Ty, indent: string): string {
		const k = this.rng.below(6);
		let head = "";
		if ((k <= 2) && this.entsOf(EntKind.ConvS, t).length == 0) { head = this.cvDeclStruct(t, indent, false); }
		if ((k == 3 || k == 4) && this.entsOf(EntKind.ConvC, t).length == 0) { head = this.cvDeclObject(t, indent, false); }
		if (k <= 2) {
			const z = this.pickEnt(this.entsOf(EntKind.ConvS, t)).name;
			if (k == 0) { return head + indent + z + ".cvShift(" + this.cvRefArg(t) + ");\n"; }
			if (k == 1) { return head + indent + z + ".cvSwap();\n"; }
			return head + indent + z + (this.rng.chance(50) ? ".v" : ".w") + ".cvBump(" + this.cvRefArg(t) + ");\n";
		}
		if (k <= 4) {
			const v = this.pickEnt(this.entsOf(EntKind.ConvC, t)).name;
			if (k == 3) { return head + indent + v + ".cvShift(" + this.expr(t, 0) + ");\n"; }
			return head + indent + v + (this.rng.chance(50) ? ".v" : ".w") + ".cvBump(" + this.cvRefArg(t) + ");\n";
		}
		const arrays = this.entsOf(EntKind.ArrayVar, t);
		if (arrays.length > 0 && this.rng.chance(50)) {
			this.useHelper("ixI", "function ixI(i: int32, n: int32): int32 { const r = i % n; return r < 0 ? r + n : r; }\n");
			const a = this.pickEnt(arrays).name;
			return indent + "if (" + a + ".length > 0) { " + a + "[ixI(" + this.smallInt(0) + ", " + a + ".length)].cvBump(" + this.cvRefArg(t) + "); }\n";
		}
		const vars = this.visible(t, true);
		if (vars.length == 0) { return ""; }
		return indent + vars[this.rng.below(vars.length)].name + ".cvBump(" + this.cvRefArg(t) + ");\n";
	}

	cvDrain(t: Ty, indent: string): string {
		this.cvItems(t);
		const T = tyName(t);
		const wantObject = this.rng.chance(40);
		const useObject = wantObject && this.cvItemsClass(t);
		let head = "";
		if (useObject && this.entsOf(EntKind.ConvC, t).length == 0) { head = this.cvDeclObject(t, indent, false); }
		if (!useObject && this.entsOf(EntKind.ConvS, t).length == 0) { head = this.cvDeclStruct(t, indent, false); }
		const source = this.pickEnt(this.entsOf(useObject ? EntKind.ConvC : EntKind.ConvS, t)).name;
		const trips = useObject ? 2 : 3;
		if (!this.reserve((2 * trips) as int64)) { return head; }
		const init = this.expr(t, 0);
		const acc = this.newLocal(t);
		const x = this.entName("x");
		const savedMult = this.mult;
		this.mult = this.mult * (trips as int64);
		this.scope.push({ name: x, ty: t, writable: false });
		const value = this.expr(t, 1);
		const stop = this.rng.chance(40) ? indent + "\tif " + this.cond(1) + " { break; }\n" : "";
		this.scope.pop();
		this.mult = savedMult;
		return head + indent + "let " + acc + ": " + T + " = " + init + ";\n" +
			indent + "for (const " + x + " of " + source + ") {\n" +
			indent + "\t" + acc + " = " + value + ";\n" +
			stop +
			indent + "}\n";
	}

	cvOpStatement(t: Ty, indent: string): string {
		this.cvOps(t);
		const k = this.rng.below(isFloat(t) ? 4 : 5);
		if (k == 3) {
			const vars = this.visible(t, true);
			if (vars.length == 0) { return ""; }
			const v = vars[this.rng.below(vars.length)].name;
			if (this.rng.chance(50)) { return indent + v + " **= " + this.cvRefArg(t) + ";\n"; }
			return indent + v + " = (" + v + " ** " + this.expr(t, 0) + ");\n";
		}
		let head = "";
		if (this.entsOf(EntKind.ConvS, t).length == 0) { head = this.cvDeclStruct(t, indent, false); }
		const structs = this.entsOf(EntKind.ConvS, t);
		const z = this.pickEnt(structs).name;
		const other = this.pickEnt(structs).name;
		if (k == 0) { return head + indent + z + " = " + z + " + " + other + ";\n"; }
		if (k == 1) { return head + indent + z + " = -" + other + ";\n"; }
		if (k == 2) { return head + indent + z + " = " + other + " - " + z + ";\n"; }
		return head + indent + z + " = " + z + " * " + this.expr(t, 0) + ";\n";
	}

	maker(t: Ty): Routine {
		const name = "mk" + String(this.makerCount);
		this.makerCount = this.makerCount + 1;
		const T = tyName(t);
		const savedScope = this.scope;
		const savedEnts = this.ents;
		this.scope = [{ name: "st", ty: t, writable: true }, { name: "x", ty: t, writable: false }];
		this.ents = [];
		const next = this.routine(t, 1, FN_COST_CAP);
		this.scope = savedScope;
		this.ents = savedEnts;
		this.useHelper(name, "function " + name + "(seed: " + T + "): (x: " + T + ") => " + T + " {\n" +
			"\tlet st: " + T + " = seed;\n" +
			"\treturn (x: " + T + "): " + T + " => {\n" +
			"\t\tst = " + next.text + ";\n" +
			"\t\treturn st;\n" +
			"\t};\n}\n");
		return { text: name, cost: next.cost };
	}

	directive(line: string): void {
		for (const d of this.directives) { if (d == line) { return; } }
		this.directives.push(line);
	}

	clsName(prefix: string): string {
		const name = prefix + String(this.clsNames);
		this.clsNames = this.clsNames + 1;
		return name;
	}

	clsFlag(primary: int32, index: int32, key: W): boolean {
		return primary == index || (this.wt(key) > 0 && this.rng.chance(30));
	}

	clsAt(i: int32): ClsDef { return i < 0 ? this.clsSelf : this.classes[i]; }

	clsThis(): Ent { return { kind: EntKind.ClsObj, name: "this", ty: Ty.Int32, params: [], len: -1, cost: 0 as int64 }; }

	clsDepth(c: int32): int32 {
		let depth = 0;
		let k = this.classes[c].parent;
		while (k >= 0) {
			depth++;
			k = this.classes[k].parent;
		}
		return depth;
	}

	clsBelow(c: int32, s: int32): boolean {
		let k = c;
		while (k >= 0) {
			if (k == s) { return true; }
			k = this.classes[k].parent;
		}
		return false;
	}

	clsParams(params: Ty[]): Var[] {
		const out: Var[] = [];
		for (let i = 0; i < params.length; i++) { out.push({ name: "p" + String(i), ty: params[i], writable: false }); }
		return out;
	}

	clsScope(cls: ClsDef, params: Ty[]): Var[] {
		const out = this.clsParams(params);
		for (const f of cls.fields) {
			if (f.vis <= 1 || f.owner == cls.index) { out.push({ name: "this." + f.name, ty: f.ty, writable: false }); }
		}
		return out;
	}

	clsBody(scope: Var[], ents: Ent[], t: Ty, cap: int64, limit: int32): Routine {
		const savedScope = this.scope;
		const savedEnts = this.ents;
		this.scope = scope;
		this.ents = ents;
		this.clsLimit = limit;
		this.clsBuilding++;
		const body = this.routine(t, 1, cap);
		this.clsBuilding--;
		this.scope = savedScope;
		this.ents = savedEnts;
		return body;
	}

	clsArrow(t: Ty): Routine {
		const savedScope = this.scope;
		const savedEnts = this.ents;
		this.scope = [];
		this.ents = [];
		this.clsBuilding++;
		const f = this.lambda([t], t, 0, CLS_CAP);
		this.clsBuilding--;
		this.scope = savedScope;
		this.ents = savedEnts;
		return f;
	}

	clsMembers(cls: ClsDef, methods: boolean, t: Ty, inside: boolean): ClsMember[] {
		const out: ClsMember[] = [];
		const list = methods ? cls.methods : cls.fields;
		for (const m of list) {
			if (m.ty != t || (methods && m.writable)) { continue; }
			if (inside ? (m.vis <= 1 || m.owner == cls.index) && (!methods || m.id < this.clsLimit) : m.vis == 0) { out.push(m); }
		}
		if (!methods && !inside) {
			for (const p of cls.props) { if (p.ty == t) { out.push(p); } }
		}
		return out;
	}

	clsPick(ms: ClsMember[]): ClsMember { return ms[this.rng.below(ms.length)]; }

	clsRecv(methods: boolean, t: Ty, depth: int32): ClsRecv {
		const objs: Ent[] = [];
		for (const e of this.entsAny(EntKind.ClsObj)) {
			if (this.bodyDepth > 0 && (e.cost as int32) >= 2) { continue; }
			if (this.clsMembers(this.clsAt(e.len), methods, t, e.len < 0).length > 0) { objs.push(e); }
		}
		const fresh: int32[] = [];
		for (let i = 0; depth == 0 && i < this.classes.length; i++) {
			if (this.clsMembers(this.classes[i], methods, t, false).length > 0) { fresh.push(i); }
		}
		if (objs.length > 0 && (fresh.length == 0 || this.rng.chance(70))) {
			const o = this.pickEnt(objs);
			return { text: o.name, cls: o.len };
		}
		if (fresh.length == 0) { return { text: "", cls: 0 }; }
		const c = fresh[this.rng.below(fresh.length)];
		const cls = this.classes[c];
		if (!this.reserve(cls.ctorCost + (1 as int64))) { return { text: "", cls: 0 }; }
		return { text: "new " + cls.name + "(" + this.args(cls.ctor, depth) + ")", cls: c };
	}

	clsExpr(t: Ty, depth: int32): string {
		if (this.clsBuilding == 0 && this.classes.length < CLS_MAX && (this.classes.length == 0 || this.rng.chance(10))) { this.clsDecl(t); }
		this.famShape = Shape.Other;
		const first = this.pickW(W.ClsField, W.ClsIs);
		for (let i = 0; i < 5; i++) {
			const k = (first + i) % 5;
			if (this.w[(W.ClsField as int32) + k] == 0) { continue; }
			let text = "";
			if (k == 0) { text = this.clsFieldExpr(t, depth); }
			if (k == 1) { text = this.clsCallExpr(t, depth); }
			if (k == 2) { text = this.clsStaticExpr(t, depth); }
			if (k == 3) { text = this.clsIfaceExpr(t, depth); }
			if (k == 4) { text = this.clsIsExpr(t, depth); }
			if (text != "") { return text; }
		}
		return "";
	}

	clsFieldExpr(t: Ty, depth: int32): string {
		const r = this.clsRecv(false, t, depth);
		if (r.text == "") { return ""; }
		const m = this.clsPick(this.clsMembers(this.clsAt(r.cls), false, t, r.cls < 0));
		if (m.cost > (0 as int64) && !this.reserve(m.cost)) { return ""; }
		return r.text + "." + m.name;
	}

	clsCallExpr(t: Ty, depth: int32): string {
		const r = this.clsRecv(true, t, depth);
		if (r.text == "") { return ""; }
		const m = this.clsPick(this.clsMembers(this.clsAt(r.cls), true, t, r.cls < 0));
		if (!this.reserve(m.cost + (1 as int64))) { return ""; }
		return r.text + "." + m.name + "(" + this.args(m.params, depth) + ")";
	}

	clsStaticExpr(t: Ty, depth: int32): string {
		const reads: ClsMember[] = [];
		const calls: ClsMember[] = [];
		for (const c of this.classes) {
			for (const s of c.statics) { if (s.ty == t) { reads.push(s); } }
			for (const s of c.smeths) { if (s.ty == t) { calls.push(s); } }
		}
		if (reads.length + calls.length == 0) { return ""; }
		const k = this.rng.below(reads.length + calls.length);
		if (k < reads.length) { return this.classes[reads[k].owner].name + "." + reads[k].name; }
		const m = calls[k - reads.length];
		if (!this.reserve(m.cost + (1 as int64))) { return ""; }
		return this.classes[m.owner].name + "." + m.name + "(" + this.args(m.params, depth) + ")";
	}

	clsIfaceExpr(t: Ty, depth: int32): string {
		const reads: string[] = [];
		const calls: string[] = [];
		for (const v of this.entsAny(EntKind.ClsIfv)) {
			const ifc = this.ifaces[v.len];
			for (const f of ifc.fields) { if (f.ty == t) { reads.push(v.name + "." + f.name); } }
			for (const f of ifc.ap) { if (f.ty == t) { calls.push(v.name + "." + f.name); } }
		}
		if (reads.length + calls.length == 0) { return ""; }
		const k = this.rng.below(reads.length + calls.length);
		if (k < reads.length) { return reads[k]; }
		if (!this.reserve(CLS_CAP + (2 as int64))) { return ""; }
		return calls[k - reads.length] + "(" + this.expr(t, depth + 1) + ")";
	}

	clsIsExpr(t: Ty, depth: int32): string {
		if (this.bodyDepth > 0) { return ""; }
		const sites: string[] = [];
		for (const o of this.entsAny(EntKind.ClsObj)) {
			if (o.len < 0 || (o.cost as int32) < 2) { continue; }
			for (let d = 0; d < this.classes.length; d++) {
				if (d == o.len || !this.clsBelow(d, o.len)) { continue; }
				for (const f of this.classes[d].fields) {
					if (f.ty == t && f.vis == 0 && f.owner != o.len && this.clsBelow(f.owner, o.len)) {
						sites.push("(" + o.name + " instanceof " + this.classes[d].name + " ? " + o.name + "." + f.name + " : ");
					}
				}
			}
		}
		if (sites.length == 0) { return ""; }
		const site = sites[this.rng.below(sites.length)];
		return this.ternary(site + this.elseExpr(t, depth) + ")");
	}

	clsStatement(indent: string): string {
		if (this.classes.length == 0 || (this.classes.length < CLS_MAX && this.rng.chance(15))) { this.clsDecl(this.pickTy()); }
		const k = this.pickW(W.ClsNew, W.ClsLiteral);
		let text = "";
		if (k == 1) { text = this.clsMutate(this.rng.below(6), indent); }
		if (k == 2) { text = this.clsAlias(indent); }
		if (k == 3) { text = this.clsLoop(indent); }
		if (k == 4) { text = this.clsLiteral(indent); }
		if (text != "" || this.wt(W.ClsNew) == 0) { return text; }
		return this.clsNew(indent);
	}

	clsNew(indent: string): string {
		const cls = this.classes[this.rng.below(this.classes.length)];
		if (!this.reserve(cls.ctorCost + (1 as int64))) { return ""; }
		const value = "new " + cls.name + "(" + this.args(cls.ctor, 0) + ")";
		const name = this.entName("o");
		if (cls.iface >= 0 && this.rng.chance(30)) {
			this.ents.push({ kind: EntKind.ClsIfv, name: name, ty: Ty.Int32, params: [], len: cls.iface, cost: 0 as int64 });
			return indent + "const " + name + ": " + this.ifaces[cls.iface].name + " = " + value + ";\n";
		}
		let s = cls.index;
		while (this.classes[s].parent >= 0 && this.rng.chance(50)) { s = this.classes[s].parent; }
		const again = this.rng.chance(40);
		const pure = this.wt(W.ClsIs) > 0 && this.rng.chance(50);
		this.ents.push({ kind: EntKind.ClsObj, name: name, ty: Ty.Int32, params: [], len: s, cost: ((again ? 1 : 0) + (pure ? 2 : 0)) as int64 });
		const typed = s != cls.index || this.rng.chance(50);
		return indent + (again ? "let " : "const ") + name + (typed ? ": " + this.classes[s].name : "") + " = " + value + ";\n";
	}

	clsMutate(form: int32, indent: string): string {
		const objs = this.entsAny(EntKind.ClsObj);
		const views = this.entsAny(EntKind.ClsIfv);
		for (let i = 0; i < 6; i++) {
			const k = (form + i) % 6;
			if (k < 3 && objs.length > 0) {
				const o = this.pickEnt(objs);
				const cls = this.classes[o.len];
				const calls: ClsMember[] = [];
				const sets: ClsMember[] = [];
				for (const m of cls.methods) { if (m.vis == 0) { calls.push(m); } }
				for (const f of cls.fields) { if (f.vis == 0 && f.writable) { sets.push(f); } }
				for (const p of cls.props) { sets.push(p); }
				if (k == 0 && calls.length > 0) {
					const m = this.clsPick(calls);
					if (!this.reserve(m.cost + (1 as int64))) { continue; }
					return indent + o.name + "." + m.name + "(" + this.args(m.params, -1) + ");\n";
				}
				if (k == 1 && sets.length > 0) {
					const f = this.clsPick(sets);
					if (f.cost > (0 as int64) && !this.reserve(f.cost)) { continue; }
					return indent + o.name + "." + f.name + " = " + this.expr(f.ty, 0) + ";\n";
				}
				if (k == 2 && (o.cost as int32) % 2 == 1) {
					const subs: int32[] = [];
					for (let d = 0; d < this.classes.length; d++) { if (this.clsBelow(d, o.len)) { subs.push(d); } }
					const d = this.classes[subs[this.rng.below(subs.length)]];
					if (!this.reserve(d.ctorCost + (1 as int64))) { continue; }
					return indent + o.name + " = new " + d.name + "(" + this.args(d.ctor, 0) + ");\n";
				}
			}
			if (k == 3) {
				const sets: ClsMember[] = [];
				for (const c of this.classes) { for (const s of c.statics) { sets.push(s); } }
				if (sets.length == 0) { continue; }
				const s = this.clsPick(sets);
				return indent + this.classes[s.owner].name + "." + s.name + " = " + this.expr(s.ty, 0) + ";\n";
			}
			if (k == 4 && views.length > 0) {
				const v = this.pickEnt(views);
				const f = this.clsPick(this.ifaces[v.len].fields);
				return indent + v.name + "." + f.name + " = " + this.expr(f.ty, 0) + ";\n";
			}
			if (k == 5) {
				const calls: ClsMember[] = [];
				for (const c of this.classes) { for (const s of c.smeths) { calls.push(s); } }
				if (calls.length == 0) { continue; }
				const m = this.clsPick(calls);
				if (!this.reserve(m.cost + (1 as int64))) { continue; }
				return indent + this.classes[m.owner].name + "." + m.name + "(" + this.args(m.params, -1) + ");\n";
			}
		}
		return "";
	}

	clsAlias(indent: string): string {
		const objs = this.entsAny(EntKind.ClsObj);
		if (objs.length == 0) { return ""; }
		const o = this.pickEnt(objs);
		const cls = this.classes[o.len];
		const sets: ClsMember[] = [];
		for (const f of cls.fields) { if (f.vis == 0 && f.writable) { sets.push(f); } }
		if (sets.length == 0 || !this.reserve(2 as int64)) { return ""; }
		const alias = this.entName("o");
		let target = this.clsPick(sets);
		let decl = indent + "const " + alias + " = " + o.name + ";\n";
		if (cls.iface >= 0 && this.rng.chance(40)) {
			const ifc = this.ifaces[cls.iface];
			target = this.clsPick(ifc.fields);
			decl = indent + "const " + alias + ": " + ifc.name + " = " + o.name + ";\n";
			this.ents.push({ kind: EntKind.ClsIfv, name: alias, ty: Ty.Int32, params: [], len: cls.iface, cost: 0 as int64 });
		} else {
			this.ents.push({ kind: EntKind.ClsObj, name: alias, ty: Ty.Int32, params: [], len: o.len, cost: 0 as int64 });
		}
		const write = this.expr(target.ty, 0);
		const seen = this.newLocal(target.ty);
		return decl +
			indent + alias + "." + target.name + " = " + write + ";\n" +
			indent + "let " + seen + ": " + tyName(target.ty) + " = " + o.name + "." + target.name + ";\n";
	}

	clsLoop(indent: string): string {
		const s = this.rng.below(this.classes.length);
		const calls: ClsMember[] = [];
		for (const m of this.classes[s].methods) { if (m.vis == 0) { calls.push(m); } }
		if (calls.length == 0) { return ""; }
		const m = this.clsPick(calls);
		const sets: ClsMember[] = [];
		for (const f of this.classes[s].fields) { if (f.vis == 0 && f.writable) { sets.push(f); } }
		const subs: int32[] = [];
		for (let d = 0; d < this.classes.length; d++) { if (this.clsBelow(d, s)) { subs.push(d); } }
		const n = this.rng.between(2, 4);
		const kinds: int32[] = [];
		let made = (n as int64) * (m.cost + (2 as int64)) + (2 as int64);
		for (let i = 0; i < n; i++) {
			const d = subs[this.rng.below(subs.length)];
			kinds.push(d);
			made = made + this.classes[d].ctorCost + (1 as int64);
		}
		if (!this.reserve(made)) { return ""; }
		const items: string[] = [];
		for (const d of kinds) { items.push("new " + this.classes[d].name + "(" + this.args(this.classes[d].ctor, 0) + ")"); }
		const list = this.entName("z");
		const x = this.entName("x");
		const init = this.expr(m.ty, 0);
		const acc = this.newLocal(m.ty);
		const savedMult = this.mult;
		this.mult = this.mult * (n as int64);
		this.ents.push({ kind: EntKind.ClsObj, name: x, ty: Ty.Int32, params: [], len: s, cost: 0 as int64 });
		let body = "";
		if (sets.length > 0 && this.rng.chance(50)) {
			const f = this.clsPick(sets);
			body = indent + "\t" + x + "." + f.name + " = " + this.expr(f.ty, 1) + ";\n";
		}
		body += indent + "\t" + acc + " = " + x + "." + m.name + "(" + this.args(m.params, 0) + ");\n";
		this.ents.pop();
		this.mult = savedMult;
		for (let i = 0; i < n; i++) {
			this.ents.push({ kind: EntKind.ClsObj, name: list + "[" + String(i) + "]", ty: Ty.Int32, params: [], len: s, cost: 0 as int64 });
		}
		return indent + "const " + list + ": " + this.classes[s].name + "[] = [" + items.join(", ") + "];\n" +
			indent + "let " + acc + ": " + tyName(m.ty) + " = " + init + ";\n" +
			indent + "for (const " + x + " of " + list + ") {\n" + body + indent + "}\n";
	}

	clsLiteral(indent: string): string {
		const i = this.clsIfaceFor(this.pickTy());
		const ifc = this.ifaces[i];
		const parts: string[] = [];
		for (const f of ifc.fields) { parts.push(f.name + ": " + this.expr(f.ty, 0)); }
		for (const f of ifc.ap) {
			const body = this.lambda([f.ty], f.ty, 0, CLS_CAP);
			parts.push(f.name + ": " + body.text);
		}
		const name = this.entName("o");
		this.ents.push({ kind: EntKind.ClsIfv, name: name, ty: Ty.Int32, params: [], len: i, cost: 0 as int64 });
		return indent + "const " + name + ": " + ifc.name + " = { " + parts.join(", ") + " };\n";
	}

	clsIfaceFor(want: Ty): int32 {
		if (this.ifaces.length > 0 && this.rng.chance(40)) { return this.rng.below(this.ifaces.length); }
		const name = "Ifc" + String(this.ifaces.length);
		const fields: ClsMember[] = [];
		const ap: ClsMember[] = [];
		let text = "interface " + name + " {\n";
		const n = this.rng.between(1, 3);
		for (let i = 0; i < n; i++) {
			const t = i == 0 ? want : this.pickTy();
			const f: ClsMember = { name: this.clsName("u"), ty: t, params: [], cost: 0 as int64, owner: -1, id: 0, vis: 0, writable: true };
			fields.push(f);
			text += "\t" + f.name + ": " + tyName(t) + ";\n";
		}
		if (this.rng.chance(50)) {
			const t = this.pickTy();
			const f: ClsMember = { name: this.clsName("ap"), ty: t, params: [t], cost: CLS_CAP, owner: -1, id: 0, vis: 0, writable: true };
			ap.push(f);
			text += "\t" + f.name + ": (x: " + tyName(t) + ") => " + tyName(t) + ";\n";
		}
		this.ifaces.push({ name: name, fields: fields, ap: ap });
		this.useHelper(name, text + "}\n");
		return this.ifaces.length - 1;
	}

	clsMethod(cls: ClsDef, slot: int32, ret0: Ty, hide: boolean, mutable: boolean): string {
		let name = "";
		let params: Ty[] = [];
		let ret = ret0;
		let vis = 0;
		let mutator = false;
		let id = cls.methods.length;
		if (slot >= 0) {
			const old = cls.methods[slot];
			name = old.name;
			params = old.params;
			ret = old.ty;
			mutator = old.writable;
			id = old.id;
		} else {
			name = this.clsName("m");
			const n = this.rng.below(3);
			for (let i = 0; i < n; i++) { params.push(this.pickTy()); }
			if (hide) { vis = [0, 0, 1, 2][this.rng.below(4)]; }
			mutator = mutable && this.rng.chance(35);
		}
		const sets: ClsMember[] = [];
		if (mutator) {
			for (const f of cls.fields) {
				if (f.writable && (f.vis <= 1 || f.owner == cls.index) && (slot < 0 || f.ty == ret)) { sets.push(f); }
			}
		}
		if (slot < 0) { mutator = sets.length > 0; }
		const scope = this.clsScope(cls, params);
		const bound = CLS_CAP * ((id + 1) as int64);
		let body = "";
		if (sets.length > 0) {
			const f = this.clsPick(sets);
			ret = f.ty;
			const v = this.clsBody(scope, [this.clsThis()], f.ty, bound, id);
			body = "this." + f.name + " = " + v.text + "; return this." + f.name + ";";
		} else {
			const v = this.clsBody(scope, [this.clsThis()], ret, bound, id);
			body = "return " + v.text + ";";
		}
		const m: ClsMember = { name: name, ty: ret, params: params, cost: bound, owner: cls.index, id: id, vis: vis, writable: mutator };
		if (slot >= 0) { cls.methods[slot] = m; } else { cls.methods.push(m); }
		let sig = "";
		for (let i = 0; i < params.length; i++) { sig += (i > 0 ? ", " : "") + "p" + String(i) + ": " + tyName(params[i]); }
		return "\t" + clsMods(vis) + name + "(" + sig + "): " + tyName(ret) + " { " + body + " }\n";
	}

	clsDecl(want: Ty): void {
		if (this.clsStatics < 0) { this.clsStatics = this.wt(W.ClsDeclStatic) > 0 && this.rng.chance(40) ? 1 : 0; }
		const primary = this.pickW(W.ClsDeclPlain, W.ClsDeclVisible);
		const cls = new ClsDef();
		cls.index = this.classes.length;
		cls.name = "Cls" + String(cls.index);
		let head = "class " + cls.name;
		const open: int32[] = [];
		if (this.clsFlag(primary, 1, W.ClsDeclInherit)) {
			for (let i = 0; i < this.classes.length; i++) { if (this.clsDepth(i) < CLS_DEPTH_MAX) { open.push(i); } }
		}
		if (open.length > 0) {
			const base = this.classes[open[this.rng.below(open.length)]];
			cls.parent = base.index;
			cls.iface = base.iface;
			cls.ctor = base.ctor;
			cls.ctorCost = base.ctorCost;
			for (const f of base.fields) { cls.fields.push(f); }
			for (const p of base.props) { cls.props.push(p); }
			for (const m of base.methods) { cls.methods.push(m); }
			head += " extends " + base.name;
		}
		const hide = this.clsFlag(primary, 5, W.ClsDeclVisible);
		if (cls.parent < 0 && this.clsFlag(primary, 4, W.ClsDeclImplements)) {
			cls.iface = this.clsIfaceFor(want);
			head += " implements " + this.ifaces[cls.iface].name;
		}
		this.clsSelf = cls;
		const own: ClsMember[] = [];
		const assigned: boolean[] = [];
		let arrows = "";
		if (cls.parent < 0 && cls.iface >= 0) {
			const ifc = this.ifaces[cls.iface];
			for (const f of ifc.fields) {
				own.push({ name: f.name, ty: f.ty, params: [], cost: 0 as int64, owner: cls.index, id: 0, vis: 0, writable: true });
				assigned.push(this.rng.chance(50));
			}
			for (const f of ifc.ap) { arrows += "\t" + f.name + ": (x: " + tyName(f.ty) + ") => " + tyName(f.ty) + " = " + this.clsArrow(f.ty).text + ";\n"; }
		}
		const prefix = own.length;
		const count = this.rng.between(1, 3);
		for (let i = 0; i < count; i++) {
			const inCtor = this.rng.chance(60);
			const vis = hide && i > 0 ? [0, 0, 1, 2][this.rng.below(4)] : 0;
			const writable = !(hide && inCtor && this.rng.chance(25));
			own.push({ name: this.clsName("v"), ty: i == 0 ? want : this.pickTy(), params: [], cost: 0 as int64, owner: cls.index, id: 0, vis: vis, writable: writable });
			assigned.push(inCtor);
		}
		let fieldText = "";
		const ctorFields: ClsMember[] = [];
		for (let i = 0; i < own.length; i++) {
			const f = own[i];
			if (i == prefix) { fieldText += arrows; }
			cls.fields.push(f);
			if (assigned[i]) { ctorFields.push(f); }
			fieldText += "\t" + clsMods(f.vis) + (f.writable ? "" : "readonly ") + f.name + ": " + tyName(f.ty) + (assigned[i] ? "" : " = " + this.literal(f.ty)) + ";\n";
		}
		let ctorText = "";
		if (ctorFields.length > 0) {
			const params: Ty[] = [];
			let sig = "";
			for (let i = 0; i < ctorFields.length; i++) {
				params.push(ctorFields[i].ty);
				sig += (i > 0 ? ", " : "") + "p" + String(i) + ": " + tyName(ctorFields[i].ty);
			}
			const scope = this.clsParams(params);
			let body = "";
			let cost = 1 as int64;
			if (cls.parent >= 0) {
				const base = this.classes[cls.parent];
				const supers: string[] = [];
				for (const t of base.ctor) {
					const a = this.clsBody(scope, [], t, CLS_CAP, -1);
					supers.push(a.text);
					cost = cost + a.cost;
				}
				body += "\t\tsuper(" + supers.join(", ") + ");\n";
				cost = cost + base.ctorCost;
			}
			for (const f of ctorFields) {
				const v = this.clsBody(scope, [], f.ty, CLS_CAP, -1);
				body += "\t\tthis." + f.name + " = " + v.text + ";\n";
				cost = cost + v.cost + (1 as int64);
			}
			ctorText = "\tconstructor(" + sig + ") {\n" + body + "\t}\n";
			cls.ctor = params;
			cls.ctorCost = cost;
		}
		let propText = "";
		if (this.clsFlag(primary, 2, W.ClsDeclAccessor)) {
			const bt = this.pickTy();
			const back: ClsMember = { name: this.clsName("v"), ty: bt, params: [], cost: 0 as int64, owner: cls.index, id: 0, vis: 2, writable: true };
			cls.fields.push(back);
			const pt = this.pickTy();
			const name = this.clsName("pr");
			const get = this.clsBody(this.clsScope(cls, []), [this.clsThis()], pt, CLS_CAP, cls.methods.length);
			const put = this.clsBody(this.clsScope(cls, [pt]), [this.clsThis()], bt, CLS_CAP, cls.methods.length);
			cls.props.push({ name: name, ty: pt, params: [], cost: (get.cost > put.cost ? get.cost : put.cost) + (1 as int64), owner: cls.index, id: 0, vis: 0, writable: true });
			propText = "\tprivate " + back.name + ": " + tyName(bt) + " = " + this.literal(bt) + ";\n" +
				"\tget " + name + "(): " + tyName(pt) + " { return " + get.text + "; }\n" +
				"\tset " + name + "(p0: " + tyName(pt) + ") { this." + back.name + " = " + put.text + "; }\n";
		}
		let methodText = "";
		const methods = this.rng.between(1, 3);
		for (let i = 0; i < methods; i++) { methodText += this.clsMethod(cls, -1, i == 0 ? want : this.pickTy(), hide && i > 0, i > 0); }
		const over: int32[] = [];
		if (cls.parent >= 0) {
			for (let i = 0; i < cls.methods.length; i++) {
				if (cls.methods[i].vis == 0 && cls.methods[i].owner != cls.index) { over.push(i); }
			}
		}
		if (over.length > 0 && this.rng.chance(70)) { methodText += this.clsMethod(cls, over[this.rng.below(over.length)], want, false, false); }
		let staticText = "";
		if (this.clsStatics == 1 && this.clsFlag(primary, 3, W.ClsDeclStatic)) {
			const n = this.rng.between(1, 2);
			for (let i = 0; i < n; i++) {
				const t = this.pickTy();
				const s: ClsMember = { name: this.clsName("s"), ty: t, params: [], cost: 0 as int64, owner: cls.index, id: 0, vis: 0, writable: true };
				cls.statics.push(s);
				staticText += "\tstatic " + s.name + ": " + tyName(t) + " = " + this.literal(t) + ";\n";
			}
			const params: Ty[] = [];
			const pn = this.rng.below(3);
			let sig = "";
			for (let i = 0; i < pn; i++) {
				params.push(this.pickTy());
				sig += (i > 0 ? ", " : "") + "p" + String(i) + ": " + tyName(params[i]);
			}
			const t = this.pickTy();
			const v = this.clsBody(this.clsParams(params), [], t, CLS_CAP, -1);
			const m: ClsMember = { name: this.clsName("sm"), ty: t, params: params, cost: v.cost + (1 as int64), owner: cls.index, id: 0, vis: 0, writable: false };
			cls.smeths.push(m);
			staticText += "\tstatic " + m.name + "(" + sig + "): " + tyName(t) + " { return " + v.text + "; }\n";
			this.directive("// @skip-raiser: a static class member cannot be read on the Raiser, inbox 2026-10-09-raiser-cannot-read-a-static-class-field");
		}
		this.classes.push(cls);
		this.useHelper(cls.name, head + " {\n" + fieldText + ctorText + propText + methodText + staticText + "}\n");
	}

	clsPrints(): string {
		let out = "";
		for (const c of this.classes) {
			for (const s of c.statics) { out += "console.log(\"" + c.name + "." + s.name + " \" + String(" + c.name + "." + s.name + "));\n"; }
		}
		return out;
	}

	famStatement(indent: string, depth: int32): string {
		if (this.famTotal() == 0) { return ""; }
		const fam = this.pickFam();
		const t = this.pickTy();
		const T = tyName(t);
		if (fam == Fam.Closure) {
			const k = this.pickW(W.ClosureDecl, W.ClosureRoutine);
			if (k == 0) {
				const params: Ty[] = [];
				const n = this.rng.below(3);
				for (let i = 0; i < n; i++) { params.push(this.pickTy()); }
				const name = this.entName("c");
				const f = this.lambda(params, t, 0, FN_COST_CAP);
				this.ents.push({ kind: EntKind.Callable, name: name, ty: t, params: params, len: 0, cost: f.cost });
				return indent + "const " + name + " = " + f.text + ";\n";
			}
			if (k == 1) {
				const vars = this.visible(t, true);
				if (vars.length == 0) { return ""; }
				const v = vars[this.rng.below(vars.length)];
				const name = this.entName("c");
				const d = this.entName("q");
				this.scope.push({ name: d, ty: t, writable: false });
				const body = this.routine(t, 1, FN_COST_CAP);
				this.scope.pop();
				this.ents.push({ kind: EntKind.Effect, name: name, ty: t, params: [t], len: 0, cost: body.cost });
				const decl = indent + "const " + name + " = (" + d + ": " + T + "): void => { " + v.name + " = " + body.text + "; };\n";
				if (!this.reserve(body.cost + (1 as int64))) { return decl; }
				return decl + indent + name + "(" + this.expr(t, 0) + ");\n";
			}
			if (k == 2) {
				const effects = this.entsOf(EntKind.Effect, t);
				if (effects.length == 0) { return ""; }
				const e = effects[this.rng.below(effects.length)];
				if (!this.reserve(e.cost + (1 as int64))) { return ""; }
				return indent + e.name + "(" + this.expr(t, 0) + ");\n";
			}
			if (k == 3) {
				const mk = this.maker(t);
				const name = this.entName("k");
				const text = indent + "const " + name + " = " + mk.text + "(" + this.expr(t, 0) + ");\n";
				this.ents.push({ kind: EntKind.Callable, name: name, ty: t, params: [t], len: 0, cost: mk.cost });
				return text;
			}
			if (k == 5) { return this.routineDecl(t, indent); }
			const name = this.entName("a");
			const j = this.entName("j");
			const n = this.rng.between(1, 4);
			this.scope.push({ name: j, ty: Ty.Int32, writable: false });
			const body = this.lambda([t], t, 0, FN_COST_CAP);
			this.scope.pop();
			this.ents.push({ kind: EntKind.ClosureArray, name: name, ty: t, params: [t], len: n, cost: body.cost });
			return indent + "const " + name + ": ((x: " + T + ") => " + T + ")[] = [];\n" +
				indent + "for (let " + j + ": int32 = 0; " + j + " < " + String(n) + "; " + j + "++) { " + name + ".push(" + body.text + "); }\n";
		}
		if (fam == Fam.Agg) { return this.aggStatement(t, indent); }
		if (fam == Fam.Coll) { return this.collStatement(t, indent); }
		if (fam == Fam.Str) { return this.strStatement(indent); }
		if (fam == Fam.Own) { return this.ownStatement(t, indent); }
		if (fam == Fam.Iter) { return this.iterStatement(t, indent, depth); }
		if (fam == Fam.Seq) { return this.seqStatement(t, indent); }
		if (fam == Fam.Gcls) { return this.gclsStatement(t, indent); }
		if (fam == Fam.Enum) { return this.enumStatement(t, indent, depth); }
		if (fam == Fam.Exc) { return this.excStatement(t, indent, depth); }
		if (fam == Fam.Native) { return this.nativeStatement(t, indent, depth); }
		if (fam == Fam.Cls) { return this.clsStatement(indent); }
		if (fam == Fam.Conv) { return this.convStatement(t, indent); }
		if (fam == Fam.Union) {
			this.unionHelpers(t);
			const vars = this.entsOf(EntKind.UnionVar, t);
			if (vars.length > 0 && this.rng.chance(50)) {
				const u = vars[this.rng.below(vars.length)];
				const k = this.rng.below(3);
				const value = k == 0 ? "null" : k == 1 ? "\"s\" + String(" + this.expr(t, 0) + ")" : this.expr(t, 0);
				return indent + u.name + " = " + value + ";\n";
			}
			const name = this.entName("u");
			const text = indent + "let " + name + ": " + T + " | string | null = boxU" + tyTitle(t) + "(" + this.smallInt(0) + ", " + this.expr(t, 0) + ");\n";
			this.ents.push({ kind: EntKind.UnionVar, name: name, ty: t, params: [], len: 0, cost: 0 as int64 });
			return text;
		}
		this.genericHelpers();
		const boxes = this.entsOf(EntKind.BoxVar, t);
		if (boxes.length > 0 && this.rng.chance(50)) {
			return indent + boxes[this.rng.below(boxes.length)].name + ".v = " + this.expr(t, 0) + ";\n";
		}
		const name = this.entName("b");
		const text = indent + "const " + name + " = new BoxG<" + T + ">(" + this.expr(t, 0) + ");\n";
		this.ents.push({ kind: EntKind.BoxVar, name: name, ty: t, params: [], len: 0, cost: 0 as int64 });
		return text;
	}

	iterHelpers(): void {
		this.useHelper("nthI", "function nthI<T>(it: Iterator<T>, n: int32, d: T): T {\n" +
			"\tlet i: int32 = 0;\n" +
			"\tfor (const v of it) {\n" +
			"\t\tif (i == n) { return v; }\n" +
			"\t\ti++;\n" +
			"\t}\n" +
			"\treturn d;\n}\n");
		this.useHelper("lastI", "function lastI<T>(it: Iterator<T>, d: T): T {\n" +
			"\tlet r = d;\n" +
			"\tfor (const v of it) { r = v; }\n" +
			"\treturn r;\n}\n");
	}

	iterExpr(t: Ty, depth: int32): string {
		const gens = this.entsOf(EntKind.IterFn, t);
		if (gens.length == 0) { return ""; }
		const g = this.pickEnt(gens);
		if (!this.reserve(g.cost + (1 as int64))) { return ""; }
		this.iterHelpers();
		const call = g.name + "(" + this.smallInt(depth) + ")";
		if (this.pickW(W.IterNth, W.IterLast) == 0) {
			return "nthI(" + call + ", " + this.smallInt(depth) + ", " + this.expr(t, depth + 1) + ")";
		}
		return "lastI(" + call + ", " + this.expr(t, depth + 1) + ")";
	}

	iterStatement(t: Ty, indent: string, depth: int32): string {
		const gens = this.entsOf(EntKind.IterFn, t);
		const k = this.pickW(W.IterDecl, W.IterManual);
		if (k == 1 && gens.length > 0) { return this.iterDrain(t, gens, indent); }
		if (k == 2 && gens.length > 0) { return this.iterManual(t, gens, indent); }
		if (depth > 0 || this.atTop) { return ""; }
		return this.iterDecl(t, indent);
	}

	iterDecl(t: Ty, indent: string): string {
		const T = tyName(t);
		const name = this.entName("y");
		const q = this.entName("q");
		const acc = this.entName("a");
		const trips = this.rng.between(1, this.tripMax);
		const cap = FN_COST_CAP / ((4 * trips + 4) as int64);
		const u = this.pickTy();
		const outer = this.visible(u, true);
		const inner = this.entsAny(EntKind.IterFn);
		const saved = this.scope.length;
		const savedEnts = this.ents.length;
		this.scope.push({ name: q, ty: Ty.Int32, writable: false });
		const init = this.routine(t, 1, cap);
		this.scope.push({ name: acc, ty: t, writable: true });
		let pre = "";
		let cost = init.cost + (2 as int64);
		if (this.rng.chance(50)) {
			const c = this.entName("c");
			const d = this.entName("q");
			this.scope.push({ name: d, ty: t, writable: false });
			const body = this.routine(t, 1, cap);
			this.scope.pop();
			this.ents.push({ kind: EntKind.Callable, name: c, ty: t, params: [t], len: 0, cost: body.cost + (1 as int64) });
			pre = indent + "\tconst " + c + " = (" + d + ": " + T + "): " + T + " => { " + acc + " = " + body.text + "; return " + acc + "; };\n";
		}
		const i = "i" + String(this.loopCount);
		this.loopCount = this.loopCount + 1;
		this.scope.push({ name: i, ty: Ty.Int32, writable: false });
		const value = this.routine(t, 1, cap);
		let each = value.cost + (2 as int64);
		let body = indent + "\t\tyield " + value.text + ";\n";
		if (this.rng.chance(50)) {
			const step = this.routine(t, 1, cap);
			each = each + step.cost + (1 as int64);
			const line = indent + "\t\t" + acc + " = " + step.text + ";\n";
			body = this.rng.chance(50) ? line + body : body + line;
		}
		if (outer.length > 0 && this.rng.chance(50)) {
			const v = outer[this.rng.below(outer.length)];
			const write = this.routine(u, 1, cap);
			each = each + write.cost + (1 as int64);
			body += indent + "\t\t" + v.name + " = " + write.text + ";\n";
		}
		if (inner.length > 0 && this.rng.chance(50)) {
			const m = this.pickEnt(inner);
			const x = this.entName("x");
			this.scope.push({ name: x, ty: m.ty, writable: false });
			const fold = this.routine(t, 1, cap);
			this.scope.pop();
			const drain = m.cost + (m.len as int64) * (fold.cost + (1 as int64));
			if (drain <= cap * (4 as int64)) {
				each = each + drain;
				body += indent + "\t\tfor (const " + x + " of " + m.name + "(" + i + ")) { " + acc + " = " + fold.text + "; }\n";
			}
		}
		while (this.scope.length > saved) { this.scope.pop(); }
		while (this.ents.length > savedEnts) { this.ents.pop(); }
		cost = cost + (trips as int64) * each;
		this.ents.push({ kind: EntKind.IterFn, name: name, ty: t, params: [Ty.Int32], len: trips + 1, cost: cost });
		return indent + "function* " + name + "(" + q + ": int32): Iterator<" + T + "> {\n" +
			indent + "\tlet " + acc + ": " + T + " = " + init.text + ";\n" +
			pre +
			indent + "\tfor (let " + i + ": int32 = 0; " + i + " < " + q + " && " + i + " < " + String(trips) + "; " + i + "++) {\n" +
			body +
			indent + "\t}\n" +
			indent + "\tyield " + acc + ";\n" +
			indent + "}\n";
	}

	iterDrain(t: Ty, gens: Ent[], indent: string): string {
		const g = this.pickEnt(gens);
		if (!this.reserve(g.cost + (1 as int64))) { return ""; }
		const T = tyName(t);
		const arg = this.smallInt(0);
		const vars = this.visible(t, true);
		let head = "";
		let target = "";
		if (vars.length > 0 && this.rng.chance(50)) {
			target = vars[this.rng.below(vars.length)].name;
		} else {
			const init = this.expr(t, 0);
			target = this.newLocal(t);
			head = indent + "let " + target + ": " + T + " = " + init + ";\n";
		}
		const x = this.entName("x");
		const savedMult = this.mult;
		this.mult = this.mult * (g.len as int64);
		this.scope.push({ name: x, ty: t, writable: false });
		const value = this.expr(t, 1);
		const stop = this.rng.chance(50) ? indent + "\tif " + this.cond(1) + " { break; }\n" : "";
		this.scope.pop();
		this.mult = savedMult;
		return head + indent + "for (const " + x + " of " + g.name + "(" + arg + ")) {\n" +
			indent + "\t" + target + " = " + value + ";\n" +
			stop +
			indent + "}\n";
	}

	iterManual(t: Ty, gens: Ent[], indent: string): string {
		const a = this.pickEnt(gens);
		const b = this.pickEnt(gens);
		if (!this.reserve(a.cost + b.cost + (2 as int64))) { return ""; }
		const T = tyName(t);
		const ia = this.entName("t");
		const ib = this.entName("t");
		const ra = this.entName("r");
		const rb = this.entName("r");
		const head = indent + "const " + ia + " = " + a.name + "(" + this.smallInt(0) + ");\n" +
			indent + "const " + ib + " = " + b.name + "(" + this.smallInt(0) + ");\n";
		const init = this.expr(t, 0);
		const target = this.newLocal(t);
		const savedMult = this.mult;
		this.mult = this.mult * (a.len as int64);
		this.scope.push({ name: ra + ".value", ty: t, writable: false });
		const fa = this.expr(t, 1);
		this.scope.pop();
		this.mult = savedMult * (b.len as int64);
		this.scope.push({ name: rb + ".value", ty: t, writable: false });
		const fb = this.expr(t, 1);
		this.scope.pop();
		this.mult = savedMult;
		return head +
			indent + "let " + target + ": " + T + " = " + init + ";\n" +
			indent + "let " + ra + " = " + ia + ".next();\n" +
			indent + "let " + rb + " = " + ib + ".next();\n" +
			indent + "while (!" + ra + ".done || !" + rb + ".done) {\n" +
			indent + "\tif (!" + ra + ".done) { " + target + " = " + fa + "; " + ra + " = " + ia + ".next(); }\n" +
			indent + "\tif (!" + rb + ".done) { " + target + " = " + fb + "; " + rb + " = " + ib + ".next(); }\n" +
			indent + "}\n";
	}

	importLine(line: string): void {
		for (const d of this.imports) { if (d == line) { return; } }
		this.imports.push(line);
	}

	taskHelper(name: string, text: string): string {
		for (const n of this.taskHelperNames) { if (n == name) { return name; } }
		this.taskHelperNames.push(name);
		this.taskText += text;
		return name;
	}

	taskId(): string {
		const id = String(this.taskCount);
		this.taskCount++;
		return id;
	}

	pickOf(tys: Ty[]): Ty { return tys[this.rng.below(tys.length)]; }

	wireTys(): Ty[] {
		const out: Ty[] = [];
		for (const t of this.tys) { if (wireSafe(t)) { out.push(t); } }
		if (out.length == 0) { out.push(Ty.Int32); }
		return out;
	}

	joinTys(): Ty[] {
		const out: Ty[] = [];
		for (const t of this.tys) { if (joinSafe(t)) { out.push(t); } }
		if (out.length == 0) { out.push(Ty.Int32); }
		return out;
	}

	intWireTys(): Ty[] {
		const out: Ty[] = [];
		for (const t of this.wireTys()) { if (!isFloat(t)) { out.push(t); } }
		if (out.length == 0) { out.push(Ty.Int32); }
		return out;
	}

	smallLit(t: Ty): string {
		if (isFloat(t)) { return ["0.25", "1.5", "3.0", "0.125"][this.rng.below(4)]; }
		return intLiteral(t, isSigned(t) && this.rng.chance(30), this.rng.below(100) as uint64);
	}

	unsignedLit(t: Ty): string { return intLiteral(t, false, this.rng.below(100) as uint64); }

	litList(t: Ty, n: int32, small: boolean): string {
		let out = "";
		for (let i = 0; i < n; i++) { out += (i == 0 ? "" : ", ") + (small ? this.smallLit(t) : this.literal(t)); }
		return out;
	}

	worker(ret: Ty, params: Ty[]): Worker {
		const savedScope = this.scope;
		const savedEnts = this.ents;
		const savedGlobals = this.globals;
		const savedFns = this.fns;
		const savedFams = this.fams;
		const savedNodes = this.nodesLeft;
		const savedCost = this.cost;
		const savedCap = this.costCap;
		const savedMult = this.mult;
		this.scope = [];
		this.ents = [];
		this.globals = [];
		this.fns = [];
		this.fams = [];
		this.nodesLeft = TASK_NODE_CAP;
		this.entCount = 0;
		this.localCount = 0;
		this.loopCount = 0;
		this.cost = 0 as int64;
		this.costCap = WORKER_COST_CAP;
		this.mult = 1 as int64;
		let sig = "";
		for (let p = 0; p < params.length; p++) {
			const name = "p" + String(p);
			this.scope.push({ name: name, ty: params[p], writable: false });
			sig = sig == "" ? name + ": " + tyName(params[p]) : sig + ", " + name + ": " + tyName(params[p]);
		}
		const body = this.block(0, "\t", false, ret, true);
		this.ents = [];
		const tail = "\treturn " + this.expr(ret, 0) + ";\n";
		const cost = this.cost;
		const name = "work" + String(this.workCount);
		this.workCount++;
		this.scope = savedScope;
		this.ents = savedEnts;
		this.globals = savedGlobals;
		this.fns = savedFns;
		this.fams = savedFams;
		this.nodesLeft = savedNodes;
		this.cost = savedCost;
		this.costCap = savedCap;
		this.mult = savedMult;
		return { name: name, text: "function " + name + "(" + sig + "): " + tyName(ret) + " {\n" + body + tail + "}\n", cost: cost };
	}

	checkLine(id: string, par: string, seq: string): string {
		this.taskHelper("taskCheck", TASK_CHECK);
		const model = this.taskPlant ? " + String(modelDelta())" : "";
		return "\ttaskCheck(\"task" + id + "\", " + par + ", " + seq + model + ");\n";
	}

	addScenario(id: string, decls: string, body: string): boolean {
		this.taskText += decls + "async function task" + id + "(): Promise<void> {\n" + body + "}\n";
		this.taskCalls += "await task" + id + "();\n";
		return true;
	}

	spawnFan(all: boolean): boolean {
		const n = this.rng.between(2, MAX_TASKS);
		const ret = this.pickOf(all ? this.joinTys() : this.wireTys());
		const params: Ty[] = [ret];
		if (this.rng.chance(50)) { params.push(this.pickOf(this.wireTys())); }
		const w = this.worker(ret, params);
		if (!this.reserve(((2 * n) as int64) * (w.cost + (4 as int64)))) { return false; }
		if (all) { this.directive(SKIP_RAISER_ALL); }
		const id = this.taskId();
		const N = String(n);
		let body = "";
		let args = "";
		let seqArgs = "";
		for (let p = 0; p < params.length; p++) {
			const k = String(p);
			body += "\tconst xs" + k + ": " + tyName(params[p]) + "[] = [" + this.litList(params[p], n, false) + "];\n";
			args += (p == 0 ? "" : ", ") + "a" + k;
			seqArgs += (p == 0 ? "" : ", ") + "xs" + k + "[i]";
		}
		body += "\tconst hs: Promise<" + tyName(ret) + ">[] = [];\n";
		body += "\tfor (let i: int32 = 0; i < " + N + "; i++) {\n";
		for (let p = 0; p < params.length; p++) { body += "\t\tconst a" + String(p) + " = xs" + String(p) + "[i];\n"; }
		body += "\t\ths.push(spawn(() => " + w.name + "(" + args + ")));\n";
		body += "\t}\n";
		body += "\tlet par = \"\";\n";
		if (all) {
			body += "\tconst rs = await Promise.all(hs);\n";
			body += "\tfor (let i: int32 = 0; i < " + N + "; i++) { par = par + String(rs[i]) + \",\"; }\n";
		} else {
			body += "\tfor (let i: int32 = 0; i < " + N + "; i++) {\n\t\tconst r = await hs[i];\n\t\tpar = par + String(r) + \",\";\n\t}\n";
		}
		body += "\tlet seq = \"\";\n";
		body += "\tfor (let i: int32 = 0; i < " + N + "; i++) { seq = seq + String(" + w.name + "(" + seqArgs + ")) + \",\"; }\n";
		body += this.checkLine(id, "par", "seq");
		return this.addScenario(id, w.text, body);
	}

	spawnMove(): boolean {
		if (!this.reserve(200 as int64)) { return false; }
		const id = this.taskId();
		let decls = "";
		let body = "";
		if (this.rng.chance(50)) {
			const t = this.pickOf(this.intWireTys());
			const T = tyName(t);
			const n = this.rng.between(2, 6);
			const lits = this.litList(t, n, true);
			const extra = this.smallLit(t);
			this.taskHelper(foldName(t), foldText(t));
			body += "\tconst arr: " + T + "[] = [" + lits + "];\n";
			body += "\tconst h = spawn(() => { arr.push(" + extra + "); return " + foldName(t) + "(arr); }, { move: [arr] });\n";
			body += "\tconst par = String(await h);\n";
			body += "\tconst ref: " + T + "[] = [" + lits + "];\n";
			body += "\tref.push(" + extra + ");\n";
			body += "\tconst seq = String(" + foldName(t) + "(ref));\n";
		} else {
			const shape = "Cnt" + id;
			const bump = "bump" + id;
			const start = String(this.rng.between(0, 99));
			const by = String(this.rng.between(1, 9));
			decls = "interface " + shape + " { n: int32; }\n" +
				"function " + bump + "(c: " + shape + "): int32 { c.n = c.n + " + by + "; return c.n; }\n";
			body += "\tconst c: " + shape + " = { n: " + start + " };\n";
			body += "\tconst h = spawn(() => " + bump + "(c), { move: [c] });\n";
			body += "\tconst par = String(await h);\n";
			body += "\tconst d: " + shape + " = { n: " + start + " };\n";
			body += "\tconst seq = String(" + bump + "(d));\n";
		}
		body += this.checkLine(id, "par", "seq");
		return this.addScenario(id, decls, body);
	}

	spawnShare(): boolean {
		if (!this.reserve(200 as int64)) { return false; }
		const id = this.taskId();
		const t = this.pickOf(this.intWireTys());
		const T = tyName(t);
		const m = this.rng.between(2, 4);
		this.taskHelper(foldName(t), foldText(t));
		let body = "\tconst ro: " + T + "[] = [" + this.litList(t, this.rng.between(2, 8), true) + "];\n";
		for (let j = 0; j < m; j++) {
			body += "\tconst h" + String(j) + " = spawn(() => " + foldName(t) + "(ro) + " + String(j) + ");\n";
		}
		let par = "";
		let seq = "";
		for (let j = 0; j < m; j++) {
			body += "\tconst r" + String(j) + " = await h" + String(j) + ";\n";
			par += (j == 0 ? "" : " + \",\" + ") + "String(r" + String(j) + ")";
			seq += (j == 0 ? "" : " + \",\" + ") + "String(" + foldName(t) + "(ro) + " + String(j) + ")";
		}
		body += this.checkLine(id, par, seq);
		return this.addScenario(id, "", body);
	}

	spawnLocked(): boolean {
		if (!this.reserve(200 as int64)) { return false; }
		this.directive(SKIP_JS_LOCKED);
		this.directive(SKIP_RAISER_CELLS);
		this.importLine("import { lockedUpdate, lockedRead } from \"std/core/promise\";");
		const id = this.taskId();
		const xor = this.rng.chance(40);
		const t = xor ? Ty.Uint32 : Ty.Int32;
		const T = tyName(t);
		const n = this.rng.between(2, MAX_TASKS);
		const bump = "lock" + (xor ? "Xor" : "Add") + id;
		const decls = "function " + bump + "(s: Locked<" + T + ">, by: " + T + "): " + T + " {\n" +
			"\tlockedUpdate(s, (v: " + T + "): " + T + " => v " + (xor ? "^" : "+") + " by);\n" +
			"\treturn by;\n" +
			"}\n";
		const N = String(n);
		let body = "\tconst cell: Locked<" + T + "> = new Locked(" + zero(t) + ");\n";
		let lits = "";
		for (let i = 0; i < n; i++) { lits += (i == 0 ? "" : ", ") + this.unsignedLit(t); }
		body += "\tconst xs: " + T + "[] = [" + lits + "];\n";
		body += "\tconst hs: Promise<" + T + ">[] = [];\n";
		body += "\tfor (let i: int32 = 0; i < " + N + "; i++) {\n\t\tconst v = xs[i];\n\t\ths.push(spawn(() => " + bump + "(cell, v)));\n\t}\n";
		body += "\tfor (const h of hs) { await h; }\n";
		body += "\tconst par = String(lockedRead(cell, (v: " + T + "): " + T + " => v));\n";
		body += "\tlet seq: " + T + " = " + zero(t) + ";\n";
		body += "\tfor (let i: int32 = 0; i < " + N + "; i++) { seq = seq " + (xor ? "^" : "+") + " xs[i]; }\n";
		body += this.checkLine(id, "par", "String(seq)");
		return this.addScenario(id, decls, body);
	}

	spawnArc(): boolean {
		if (!this.reserve(200 as int64)) { return false; }
		this.directive(SKIP_JS_ARC);
		this.directive(SKIP_RAISER_CELLS);
		const id = this.taskId();
		const n = this.rng.between(2, MAX_TASKS);
		const shape = "Payload" + id;
		const mix = "mix" + id;
		const weigh = "weigh" + id;
		const a = this.smallLit(Ty.Int32);
		const b = this.smallLit(Ty.Int32);
		const decls = "struct " + shape + " { n: int32; m: int32; }\n" +
			"function " + mix + "(n: int32, m: int32): int32 { return n * 3 + m; }\n" +
			"function " + weigh + "(a: Arc<" + shape + ">): int32 { return " + mix + "(a.n, a.m); }\n";
		const N = String(n);
		let body = "\tconst a: Arc<" + shape + "> = new Arc({ n: " + a + ", m: " + b + " });\n";
		body += "\tconst hs: Promise<int32>[] = [];\n";
		body += "\tfor (let i: int32 = 0; i < " + N + "; i++) { hs.push(spawn(() => " + weigh + "(a))); }\n";
		body += "\tlet par: int32 = 0;\n";
		body += "\tfor (const h of hs) { par = par + await h; }\n";
		body += "\tlet seq: int32 = 0;\n";
		body += "\tfor (let i: int32 = 0; i < " + N + "; i++) { seq = seq + " + mix + "(" + a + ", " + b + "); }\n";
		body += this.checkLine(id, "String(par)", "String(seq)");
		return this.addScenario(id, decls, body);
	}

	spawnNest(): boolean {
		const n = this.rng.between(2, MAX_TASKS);
		const params: Ty[] = [Ty.Int32];
		const w = this.worker(Ty.Int32, params);
		if (!this.reserve(((2 * n) as int64) * (w.cost + (6 as int64)))) { return false; }
		const id = this.taskId();
		const N = String(n);
		const by = String(this.rng.between(1, 9));
		let body = "\tconst xs: int32[] = [" + this.litList(Ty.Int32, n, false) + "];\n";
		body += "\tconst hs: Promise<int32>[] = [];\n";
		body += "\tfor (let i: int32 = 0; i < " + N + "; i++) {\n";
		body += "\t\tconst a = xs[i];\n";
		body += "\t\ths.push(spawn(() => {\n\t\t\tconst g = spawn(() => " + w.name + "(a));\n\t\t\treturn (await g) ^ " + by + ";\n\t\t}));\n";
		body += "\t}\n";
		body += "\tlet par = \"\";\n";
		body += "\tfor (let i: int32 = 0; i < " + N + "; i++) {\n\t\tconst r = await hs[i];\n\t\tpar = par + String(r) + \",\";\n\t}\n";
		body += "\tlet seq = \"\";\n";
		body += "\tfor (let i: int32 = 0; i < " + N + "; i++) { seq = seq + String(" + w.name + "(xs[i]) ^ " + by + ") + \",\"; }\n";
		body += this.checkLine(id, "par", "seq");
		return this.addScenario(id, w.text, body);
	}

	spawnFail(): boolean {
		const n = this.rng.between(2, MAX_TASKS);
		const w = this.worker(Ty.Int32, [Ty.Int32]);
		if (!this.reserve(((2 * n) as int64) * (w.cost + (6 as int64)))) { return false; }
		const id = this.taskId();
		const N = String(n);
		const every = String(this.rng.between(2, 4));
		const fail = "fail" + id;
		const decls = w.text + "function " + fail + "(a: int32): int32 {\n" +
			"\tif (a % " + every + " == 0) { throw new Error(\"bad\"); }\n" +
			"\treturn " + w.name + "(a);\n" +
			"}\n";
		let xs = "";
		for (let i = 0; i < n; i++) { xs += (i == 0 ? "" : ", ") + String(this.rng.between(0, 12)); }
		let body = "\tconst xs: int32[] = [" + xs + "];\n";
		body += "\tconst hs: Promise<int32>[] = [];\n";
		body += "\tfor (let i: int32 = 0; i < " + N + "; i++) {\n\t\tconst a = xs[i];\n\t\ths.push(spawn(() => " + fail + "(a)));\n\t}\n";
		body += "\tlet ok: int32 = 0;\n\tlet bad: int32 = 0;\n\tlet sum: int64 = 0;\n";
		body += "\tfor (let i: int32 = 0; i < " + N + "; i++) {\n";
		body += "\t\ttry {\n\t\t\tconst v = await hs[i];\n\t\t\tok++;\n\t\t\tsum = sum + (v as int64);\n\t\t} catch (e) {\n\t\t\tbad++;\n\t\t}\n\t}\n";
		body += "\tlet okSeq: int32 = 0;\n\tlet badSeq: int32 = 0;\n\tlet sumSeq: int64 = 0;\n";
		body += "\tfor (let i: int32 = 0; i < " + N + "; i++) {\n";
		body += "\t\ttry {\n\t\t\tconst v = " + fail + "(xs[i]);\n\t\t\tokSeq++;\n\t\t\tsumSeq = sumSeq + (v as int64);\n\t\t} catch (e) {\n\t\t\tbadSeq++;\n\t\t}\n\t}\n";
		body += this.checkLine(id, "String(ok) + \"/\" + String(bad) + \"/\" + String(sum)", "String(okSeq) + \"/\" + String(badSeq) + \"/\" + String(sumSeq)");
		return this.addScenario(id, decls, body);
	}

	spawnTimed(): boolean {
		const n = this.rng.between(1, 3);
		const ret = this.pickOf(this.wireTys());
		const params: Ty[] = [ret];
		const w = this.worker(ret, params);
		if (!this.reserve(((2 * n) as int64) * (w.cost + (4 as int64)))) { return false; }
		this.directive(SKIP_RAISER_TIMED);
		const id = this.taskId();
		let body = "{\n";
		let par = "";
		let seq = "";
		for (let i = 0; i < n; i++) {
			const k = String(i);
			const lit = this.literal(params[0]);
			body += "\tconst a" + k + ": " + tyName(params[0]) + " = " + lit + ";\n";
			body += "\tconst v" + k + " = await spawn(() => " + w.name + "(a" + k + "), { timeout: 60000 });\n";
			par += (i == 0 ? "" : " + \",\" + ") + "String(v" + k + ")";
			seq += (i == 0 ? "" : " + \",\" + ") + "String(" + w.name + "(a" + k + "))";
		}
		body += this.checkLine(id, par, seq);
		body += "}\n";
		this.taskText += w.text;
		this.taskCalls += body;
		return true;
	}

	spawnScenario(): boolean {
		const k = this.pickW(W.SpawnFan, W.SpawnTimed);
		if (k == 0) { return this.spawnFan(false); }
		if (k == 1) { return this.spawnFan(true); }
		if (k == 2) { return this.spawnMove(); }
		if (k == 3) { return this.spawnShare(); }
		if (k == 4) { return this.spawnLocked(); }
		if (k == 5) { return this.spawnArc(); }
		if (k == 6) { return this.spawnNest(); }
		if (k == 7) { return this.spawnFail(); }
		return this.spawnTimed();
	}

	actorMethod(name: string, id: string): string { return name + "_" + id; }

	actorScenario(mode: int32, many: boolean): boolean {
		const fields = this.rng.between(1, 3);
		const tys: Ty[] = [];
		const inits: string[] = [];
		for (let f = 0; f < fields; f++) {
			tys.push(this.pickOf(this.wireTys()));
			inits.push(this.smallLit(tys[f]));
		}
		const withText = this.rng.chance(50);
		const actors = many ? this.rng.between(2, 3) : 1;
		const n = this.rng.between(2, MAX_TASKS);
		if (!this.reserve(((actors * n * 2) as int64) * (10 as int64))) { return false; }
		this.directive(SKIP_RAISER_ACTOR);
		for (const t of tys) { this.taskHelper(stepName(t), stepText(t)); }
		const id = this.taskId();
		const A = "Act" + id;
		let decls = "actor " + A + " {\n";
		for (let f = 0; f < fields; f++) { decls += "\tst" + String(f) + ": " + tyName(tys[f]) + " = " + inits[f] + ";\n"; }
		if (withText) { decls += "\ttxt: string = \"\";\n"; }
		decls += "\t" + this.actorMethod("add", id) + "(v: int32): void {\n";
		for (let f = 0; f < fields; f++) {
			const s = "this.st" + String(f);
			decls += "\t\t" + s + " = " + stepName(tys[f]) + "(" + s + ", v);\n";
		}
		if (withText) { decls += "\t\tthis.txt = this.txt + String(v) + \",\";\n"; }
		decls += "\t}\n";
		decls += "\t" + this.actorMethod("bump", id) + "(v: int32): " + tyName(tys[0]) + " {\n\t\tthis.st0 = " + stepName(tys[0]) + "(this.st0, v);\n\t\treturn this.st0;\n\t}\n";
		for (let f = 0; f < fields; f++) {
			decls += "\t" + this.actorMethod("get" + String(f), id) + "(): " + tyName(tys[f]) + " { return this.st" + String(f) + "; }\n";
		}
		if (withText) { decls += "\t" + this.actorMethod("getTxt", id) + "(): string { return this.txt; }\n"; }
		decls += "}\n";
		let vs = "";
		for (let i = 0; i < n; i++) { vs += (i == 0 ? "" : ", ") + String(this.rng.between(0, 99)); }
		let body = "";
		for (let k = 0; k < actors; k++) {
			const ak = String(k);
			body += "\tconst a" + ak + " = new " + A + "();\n";
			for (let f = 0; f < fields; f++) { body += "\tlet m" + ak + "_" + String(f) + ": " + tyName(tys[f]) + " = " + inits[f] + ";\n"; }
			if (withText) { body += "\tlet mt" + ak + " = \"\";\n"; }
		}
		body += "\tlet rep = \"\";\n\tlet rsq = \"\";\n";
		body += "\tconst vs: int32[] = [" + vs + "];\n";
		body += "\tfor (let i: int32 = 0; i < " + String(n) + "; i++) {\n\t\tconst v = vs[i];\n";
		for (let k = 0; k < actors; k++) {
			const ak = String(k);
			const arg = k == 0 ? "v" : "v + " + ak;
			body += "\t\ta" + ak + "." + this.actorMethod("add", id) + "(" + arg + ");\n";
			for (let f = 0; f < fields; f++) {
				const m = "m" + ak + "_" + String(f);
				body += "\t\t" + m + " = " + stepName(tys[f]) + "(" + m + ", " + arg + ");\n";
			}
			if (withText) { body += "\t\tmt" + ak + " = mt" + ak + " + String(" + arg + ") + \",\";\n"; }
		}
		if (mode == 1) {
			body += "\t\tif (i % 2 == 1) {\n";
			body += "\t\t\tconst r = await a0." + this.actorMethod("bump", id) + "(i);\n";
			body += "\t\t\tm0_0 = " + stepName(tys[0]) + "(m0_0, i);\n";
			body += "\t\t\trep = rep + String(r) + \",\";\n";
			body += "\t\t\trsq = rsq + String(m0_0) + \",\";\n";
			body += "\t\t}\n";
		}
		body += "\t}\n";
		let par = "";
		let seq = "";
		for (let k = 0; k < actors; k++) {
			const ak = String(k);
			for (let f = 0; f < fields; f++) {
				body += "\tconst q" + ak + "_" + String(f) + " = await a" + ak + "." + this.actorMethod("get" + String(f), id) + "();\n";
				par += (par == "" ? "" : " + \",\" + ") + "String(q" + ak + "_" + String(f) + ")";
				seq += (seq == "" ? "" : " + \",\" + ") + "String(m" + ak + "_" + String(f) + ")";
			}
			if (withText) {
				body += "\tconst qt" + ak + " = await a" + ak + "." + this.actorMethod("getTxt", id) + "();\n";
				par += " + \";\" + qt" + ak;
				seq += " + \";\" + mt" + ak;
			}
		}
		body += this.checkLine(id, par + " + \"|\" + rep", seq + " + \"|\" + rsq");
		if (mode == 2) {
			this.importLine("import { stop, ExitReason } from \"std/actor\";");
			for (let k = 0; k < actors; k++) { body += "\tstop(a" + String(k) + ".pid, ExitReason.Normal);\n"; }
		}
		return this.addScenario(id, decls, body);
	}

	actorChain(): boolean {
		if (!this.reserve(300 as int64)) { return false; }
		this.directive(SKIP_RAISER_ACTOR);
		this.taskHelper(stepName(Ty.Int32), stepText(Ty.Int32));
		const id = this.taskId();
		const n = this.rng.between(2, 8);
		const who = this.rng.between(1, 9);
		const pt = "Pt" + id;
		const area = "area" + id;
		const sink = "Sink" + id;
		const prod = "Prod" + id;
		const put = this.actorMethod("put", id);
		const putPt = this.actorMethod("putPt", id);
		const total = this.actorMethod("total", id);
		const seen = this.actorMethod("seen", id);
		const psum = this.actorMethod("psum", id);
		const run = this.actorMethod("run", id);
		const ping = this.actorMethod("ping", id);
		const decls = "struct " + pt + " { x: int32; y: int32; }\n" +
			"function " + area + "(p: " + pt + "): int32 { return p.x * p.y; }\n" +
			"actor " + sink + " {\n" +
			"\tacc: int32 = 1;\n\tcount: int32 = 0;\n\tpts: int32 = 0;\n" +
			"\t" + put + "(v: int32): void { this.acc = step_int32(this.acc, v); this.count = this.count + 1; }\n" +
			"\t" + putPt + "(p: " + pt + "): void { this.pts = (this.pts + " + area + "(p)) % 100003; }\n" +
			"\t" + total + "(): int32 { return this.acc; }\n" +
			"\t" + seen + "(): int32 { return this.count; }\n" +
			"\t" + psum + "(): int32 { return this.pts; }\n" +
			"}\n" +
			"actor " + prod + " {\n" +
			"\tsink: " + sink + ";\n\tid: int32;\n" +
			"\tconstructor(sink: " + sink + ", id: int32) { this.sink = sink; this.id = id; }\n" +
			"\t" + run + "(n: int32): void { for (let i: int32 = 0; i < n; i++) { this.sink." + put + "(this.id * 100 + i); } }\n" +
			"\t" + ping + "(): int32 { return this.id; }\n" +
			"}\n";
		const N = String(n);
		const p1 = "{ x: " + String(this.rng.between(1, 30)) + ", y: " + String(this.rng.between(1, 30)) + " }";
		const p2 = "{ x: " + String(this.rng.between(1, 30)) + ", y: " + String(this.rng.between(1, 30)) + " }";
		let body = "\tconst sink = new " + sink + "();\n";
		body += "\tconst prod = new " + prod + "(sink, " + String(who) + ");\n";
		body += "\tprod." + run + "(" + N + ");\n";
		body += "\tconst pong = await prod." + ping + "();\n";
		body += "\tconst pa: " + pt + " = " + p1 + ";\n\tconst pb: " + pt + " = " + p2 + ";\n";
		body += "\tsink." + putPt + "(pa);\n\tsink." + putPt + "(pb);\n";
		body += "\tconst total = await sink." + total + "();\n\tconst seen = await sink." + seen + "();\n\tconst psum = await sink." + psum + "();\n";
		body += "\tlet m: int32 = 1;\n";
		body += "\tfor (let i: int32 = 0; i < " + N + "; i++) { m = step_int32(m, " + String(who) + " * 100 + i); }\n";
		body += "\tconst ma: " + pt + " = " + p1 + ";\n\tconst mb: " + pt + " = " + p2 + ";\n";
		body += this.checkLine(id, "String(pong) + \",\" + String(total) + \",\" + String(seen) + \",\" + String(psum)",
			"String(" + String(who) + ") + \",\" + String(m) + \",\" + String(" + N + ") + \",\" + String((" + area + "(ma) + " + area + "(mb)) % 100003)");
		return this.addScenario(id, decls, body);
	}

	actorSpawn(): boolean {
		if (!this.reserve(300 as int64)) { return false; }
		this.directive(SKIP_RAISER_ACTOR);
		this.taskHelper(foldName(Ty.Int32), foldText(Ty.Int32));
		const id = this.taskId();
		const n = this.rng.between(2, 8);
		const vault = "Vault" + id;
		const put = this.actorMethod("put", id);
		const par = this.actorMethod("par", id);
		const size = this.actorMethod("size", id);
		const decls = "actor " + vault + " {\n" +
			"\tvals: int32[] = [];\n" +
			"\t" + put + "(v: int32): void { this.vals.push(v); }\n" +
			"\t" + par + "(): int32 {\n\t\tconst h = spawn(() => " + foldName(Ty.Int32) + "(this.vals));\n\t\treturn await h;\n\t}\n" +
			"\t" + size + "(): int32 { return this.vals.length; }\n" +
			"}\n";
		let vs = "";
		for (let i = 0; i < n; i++) { vs += (i == 0 ? "" : ", ") + String(this.rng.between(-50, 99)); }
		let body = "\tconst a = new " + vault + "();\n";
		body += "\tconst mirror: int32[] = [];\n";
		body += "\tconst vs: int32[] = [" + vs + "];\n";
		body += "\tfor (let i: int32 = 0; i < " + String(n) + "; i++) {\n\t\ta." + put + "(vs[i]);\n\t\tmirror.push(vs[i]);\n\t}\n";
		body += "\tconst folded = await a." + par + "();\n\tconst size = await a." + size + "();\n";
		body += this.checkLine(id, "String(folded) + \",\" + String(size)", "String(" + foldName(Ty.Int32) + "(mirror)) + \",\" + String(mirror.length)");
		return this.addScenario(id, decls, body);
	}

	actorShape(): boolean {
		const k = this.pickW(W.ActorState, W.ActorStop);
		if (k == 0) { return this.actorScenario(0, false); }
		if (k == 1) { return this.actorScenario(1, false); }
		if (k == 2) { return this.actorChain(); }
		if (k == 3) { return this.actorScenario(0, true); }
		if (k == 4) { return this.actorSpawn(); }
		return this.actorScenario(2, this.rng.chance(30));
	}

	raceTy(): string { return RACE_TYS[this.rng.below(RACE_TYS.length)]; }

	raceLit(t: string): string {
		if (t == "boolean") { return this.rng.chance(50) ? "true" : "false"; }
		if (t == "float64") { return ["0.5", "1.25", "2.0", "(-3.5)", "100.0"][this.rng.below(5)]; }
		return String(this.rng.between(0, 99));
	}

	distinctTicks(m: int32): int32[] {
		const pool: int32[] = [];
		for (let i = 1; i <= TICK_CAP; i++) { pool.push(i); }
		const out: int32[] = [];
		for (let i = 0; i < m; i++) {
			const k = this.rng.below(pool.length);
			out.push(pool[k]);
			pool[k] = pool[pool.length - 1];
			pool.pop();
		}
		return out;
	}

	raceFirst(tie: boolean): boolean {
		if (!this.reserve(200 as int64)) { return false; }
		this.directive(SKIP_RAISER_RACE);
		const id = this.taskId();
		const t = this.raceTy();
		this.taskHelper(ticksName(t), ticksText(t));
		const m = this.rng.between(2, 4);
		let ns: int32[] = [];
		if (tie) {
			const same = this.rng.between(1, 3);
			for (let i = 0; i < m; i++) { ns.push(same); }
		} else {
			ns = this.distinctTicks(m);
		}
		let vs = "";
		let nsText = "";
		let calls = "";
		for (let i = 0; i < m; i++) {
			const k = String(i);
			vs += (i == 0 ? "" : ", ") + this.raceLit(t);
			nsText += (i == 0 ? "" : ", ") + String(ns[i]);
			calls += (i == 0 ? "" : ", ") + ticksName(t) + "(vs[" + k + "], ns[" + k + "])";
		}
		let body = "\tconst vs: " + t + "[] = [" + vs + "];\n";
		body += "\tconst ns: int32[] = [" + nsText + "];\n";
		body += "\tlet best: int32 = 0;\n";
		body += "\tfor (let i: int32 = 1; i < " + String(m) + "; i++) { if (ns[i] < ns[best]) { best = i; } }\n";
		body += "\tconst win = await Promise.race([" + calls + "]);\n";
		body += this.checkLine(id, "String(win)", "String(vs[best])");
		return this.addScenario(id, "", body);
	}

	raceAny(): boolean {
		if (!this.reserve(200 as int64)) { return false; }
		this.directive(SKIP_RAISER_RACE);
		const id = this.taskId();
		const t = this.raceTy();
		this.taskHelper(ticksName(t), ticksText(t));
		this.taskHelper(failName(t), failText(t));
		const m = this.rng.between(2, 4);
		const ns = this.distinctTicks(m);
		const allFail = this.rng.chance(25);
		const oks: boolean[] = [];
		let okCount = 0;
		for (let i = 0; i < m; i++) {
			const ok = !allFail && this.rng.chance(50);
			oks.push(ok);
			if (ok) { okCount++; }
		}
		if (!allFail && okCount == 0) { oks[this.rng.below(m)] = true; }
		let vs = "";
		let nsText = "";
		let okText = "";
		let calls = "";
		for (let i = 0; i < m; i++) {
			const k = String(i);
			vs += (i == 0 ? "" : ", ") + this.raceLit(t);
			nsText += (i == 0 ? "" : ", ") + String(ns[i]);
			okText += (i == 0 ? "" : ", ") + (oks[i] ? "true" : "false");
			calls += (i == 0 ? "" : ", ") + (oks[i] ? ticksName(t) + "(vs[" + k + "], ns[" + k + "])" : failName(t) + "(ns[" + k + "], " + k + ")");
		}
		let body = "\tconst vs: " + t + "[] = [" + vs + "];\n";
		body += "\tconst ns: int32[] = [" + nsText + "];\n";
		body += "\tconst oks: boolean[] = [" + okText + "];\n";
		body += "\tlet best: int32 = -1;\n";
		body += "\tfor (let i: int32 = 0; i < " + String(m) + "; i++) { if (oks[i] && (best < 0 || ns[i] < ns[best])) { best = i; } }\n";
		if (allFail) {
			body += "\tlet par = \"resolved\";\n";
			body += "\ttry {\n\t\tawait Promise.any([" + calls + "]);\n\t} catch (e) {\n\t\tpar = \"rejected\";\n\t}\n";
			body += this.checkLine(id, "par", "(best < 0 ? \"rejected\" : \"resolved\")");
		} else {
			body += "\tconst win = await Promise.any([" + calls + "]);\n";
			body += this.checkLine(id, "String(win)", "String(vs[best])");
		}
		return this.addScenario(id, "", body);
	}

	raceFail(): boolean {
		if (!this.reserve(200 as int64)) { return false; }
		this.directive(SKIP_RAISER_RACE);
		const id = this.taskId();
		const all = this.rng.chance(40);
		const t = all ? tyName(this.pickOf(this.joinTys())) : this.raceTy();
		this.taskHelper(ticksName(t), ticksText(t));
		this.taskHelper(failName(t), failText(t));
		const m = all ? this.rng.between(2, 4) : this.rng.between(2, 3);
		const ns = this.distinctTicks(m);
		const fails: boolean[] = [];
		let failCount = 0;
		for (let i = 0; i < m; i++) {
			const fail = this.rng.chance(50);
			fails.push(fail);
			if (fail) { failCount++; }
		}
		if (failCount == 0) { fails[this.rng.below(m)] = true; }
		let vs = "";
		let nsText = "";
		let failFlags = "";
		let calls = "";
		for (let i = 0; i < m; i++) {
			const k = String(i);
			vs += (i == 0 ? "" : ", ") + this.raceLit(t);
			nsText += (i == 0 ? "" : ", ") + String(ns[i]);
			failFlags += (i == 0 ? "" : ", ") + (fails[i] ? "true" : "false");
			calls += (i == 0 ? "" : ", ") + (fails[i] ? failName(t) + "(ns[" + k + "], " + k + ")" : ticksName(t) + "(vs[" + k + "], ns[" + k + "])");
		}
		let body = "\tconst vs: " + t + "[] = [" + vs + "];\n";
		body += "\tconst ns: int32[] = [" + nsText + "];\n";
		body += "\tconst fails: boolean[] = [" + failFlags + "];\n";
		body += "\tlet par = \"\";\n";
		if (all) {
			body += "\ttry {\n\t\tawait Promise.all([" + calls + "]);\n\t\tpar = \"resolved\";\n\t} catch (e) {\n\t\tpar = (e as Error).message;\n\t}\n";
			body += "\tlet best: int32 = -1;\n";
			body += "\tfor (let i: int32 = 0; i < " + String(m) + "; i++) { if (fails[i] && (best < 0 || ns[i] < ns[best])) { best = i; } }\n";
			body += this.checkLine(id, "par", "\"f\" + String(best)");
		} else {
			body += "\ttry {\n\t\tpar = \"v\" + String(await Promise.race([" + calls + "]));\n\t} catch (e) {\n\t\tpar = (e as Error).message;\n\t}\n";
			body += "\tlet best: int32 = 0;\n";
			body += "\tfor (let i: int32 = 1; i < " + String(m) + "; i++) { if (ns[i] < ns[best]) { best = i; } }\n";
			body += this.checkLine(id, "par", "(fails[best] ? \"f\" + String(best) : \"v\" + String(vs[best]))");
		}
		return this.addScenario(id, "", body);
	}

	raceAbort(): boolean {
		if (!this.reserve(200 as int64)) { return false; }
		const id = this.taskId();
		const m = this.rng.between(2, 5);
		const guard = "guard" + id;
		const decls = "function " + guard + "(s: AbortSignal, v: int32): int32 { return s.aborted ? -1 : v; }\n";
		let plan = "";
		let vs = "";
		for (let i = 0; i < m; i++) {
			plan += (i == 0 ? "" : ", ") + (this.rng.chance(50) ? "true" : "false");
			vs += (i == 0 ? "" : ", ") + String(this.rng.between(0, 99));
		}
		const M = String(m);
		let body = "\tconst plan: boolean[] = [" + plan + "];\n";
		body += "\tconst vs: int32[] = [" + vs + "];\n";
		body += "\tconst cs: AbortController[] = [];\n";
		body += "\tfor (let i: int32 = 0; i < " + M + "; i++) { cs.push(new AbortController()); }\n";
		body += "\tfor (let i: int32 = 0; i < " + M + "; i++) {\n\t\tif (plan[i]) {\n\t\t\tconst c = cs[i];\n\t\t\tc.abort(\"stop\");\n\t\t}\n\t}\n";
		body += "\tlet par = \"\";\n\tlet seq = \"\";\n";
		body += "\tfor (let i: int32 = 0; i < " + M + "; i++) {\n";
		body += "\t\tpar = par + String(cs[i].signal.aborted) + String(" + guard + "(cs[i].signal, vs[i])) + \",\";\n";
		body += "\t\tseq = seq + String(plan[i]) + String(plan[i] ? -1 : vs[i]) + \",\";\n";
		body += "\t}\n";
		body += "\tconst pre = AbortSignal.abort(\"done\");\n";
		body += "\tpar = par + String(pre.aborted);\n";
		body += "\tseq = seq + \"true\";\n";
		body += this.checkLine(id, "par", "seq");
		return this.addScenario(id, decls, body);
	}

	raceTimer(): boolean {
		if (!this.reserve(200 as int64)) { return false; }
		this.directive(SKIP_RAISER_RACE);
		const id = this.taskId();
		const t = this.raceTy();
		this.taskHelper(ticksName(t), ticksText(t));
		this.taskHelper(lateName(t), lateText(t));
		const quick = this.raceLit(t);
		const slow = this.raceLit(t);
		const ticks = String(this.rng.between(1, 3));
		const ms = String(this.rng.between(100, 150));
		let body = "";
		if (this.rng.chance(50)) {
			body += "\tconst win = await Promise.race([" + ticksName(t) + "(" + quick + ", " + ticks + "), " + lateName(t) + "(" + slow + ", " + ms + ")]);\n";
			body += this.checkLine(id, "String(win)", "String(" + quick + ")");
		} else {
			this.taskHelper(failName(t), failText(t));
			body += "\tconst win = await Promise.any([" + failName(t) + "(" + ticks + ", 7), " + lateName(t) + "(" + slow + ", " + ms + ")]);\n";
			body += this.checkLine(id, "String(win)", "String(" + slow + ")");
		}
		return this.addScenario(id, "", body);
	}

	raceScenario(): boolean {
		const k = this.pickW(W.RaceFirst, W.RaceTimer);
		if (k == 0) { return this.raceFirst(false); }
		if (k == 1) { return this.raceFirst(true); }
		if (k == 2) { return this.raceAny(); }
		if (k == 3) { return this.raceFail(); }
		if (k == 4) { return this.raceAbort(); }
		return this.raceTimer();
	}

	taskFamPick(): Fam {
		let total = 0;
		for (const f of this.taskFams) { total += this.w[(W.FamClosure as int32) + (f as int32)]; }
		let k = this.rng.below(total);
		for (const f of this.taskFams) {
			const n = this.w[(W.FamClosure as int32) + (f as int32)];
			if (k < n) { return f; }
			k -= n;
		}
		unreachable;
	}

	taskScenarios(forced: boolean): void {
		this.directive("// @serial");
		this.cost = 0 as int64;
		this.costCap = TASK_COST_CAP;
		this.mult = 1 as int64;
		if (forced) {
			this.spawnFan(false);
			return;
		}
		const count = this.rng.between(1, 3);
		for (let s = 0; s < count; s++) {
			const fam = this.taskFamPick();
			if (fam == Fam.Spawn) {
				this.spawnScenario();
			} else if (fam == Fam.Actor) {
				this.actorShape();
			} else {
				this.raceScenario();
			}
		}
	}

	skipHostLanes(): void {
		this.directive(SKIP_JS);
		this.directive(SKIP_RAISER);
	}

	natExtern(name: string): string {
		for (let i = 0; i < NAT_EXTERNS.length; i += 4) {
			if (NAT_EXTERNS[i] != name) { continue; }
			const header = NAT_EXTERNS[i + 1];
			if (header != "") { this.useHelper("natInclude" + header, "@include(\"" + header + "\")\n"); }
			return this.useHelper(name, "extern function " + name + NAT_EXTERNS[i + 2] + " from \"" + NAT_EXTERNS[i + 3] + "\";\n");
		}
		unreachable;
	}

	natHelpers(): void {
		this.useHelper("natCheck", "function natCheck(ok: boolean, what: string): void { if (!ok) { throw new Error(\"native invariant \" + what); } }\n" +
			"function natSameF64(a: float64, b: float64): boolean { return a == b || (a != a && b != b); }\n");
	}

	natStructs(t: Ty): string {
		this.natHelpers();
		const T = tyName(t);
		const X = tyTitle(t);
		const S = "NatS" + X;
		this.useHelper(S, "struct " + S + " { n: " + T + "; k: uint8; m: " + T + "; }\n" +
			"struct NatO" + X + " { head: " + S + "; tail: " + S + "; }\n" +
			"function natPut" + X + "(p: Ptr<" + S + ">, a: " + T + ", b: " + T + "): void { p.n = a; p[].m = b; }\n" +
			"function natGet" + X + "(p: Ptr<" + S + ">, second: boolean): " + T + " { return second ? p[].m : p.n; }\n" +
			"function natBorrow" + X + "(b: Borrow<" + S + ">): " + T + " { return b.n; }\n" +
			"function natCursor" + X + "(c: Cursor<" + S + ">): " + T + " { return c.m; }\n" +
			"function natRef" + X + "(r: Ref<" + S + ">, a: " + T + "): void { r.n = a; }\n");
		return X;
	}

	natIx(): void {
		this.useHelper("ixI", "function ixI(i: int32, n: int32): int32 { const r = i % n; return r < 0 ? r + n : r; }\n");
	}

	natSign(): void {
		this.useHelper("natSign", "function natSign(x: int32): int32 { return x < 0 ? -1 : x > 0 ? 1 : 0; }\n");
	}

	natLen(): void {
		this.natExtern("natStrlen");
		this.useHelper("natLen", "function natLen(c: cstring): int32 { return natStrlen(c) as int32; }\n");
	}

	natCast(from: Ty, to: Ty, text: string): string {
		if (from == to) { return text; }
		if (fitsRaw(from, to)) { return "(" + text + " as " + tyName(to) + ")"; }
		return this.convHelper(from, to) + "(" + text + ")";
	}

	natResult(t: Ty, from: Ty, value: string, indent: string): string {
		const text = this.natCast(from, t, value);
		return indent + "let " + this.newLocal(t) + ": " + tyName(t) + " = " + text + ";\n";
	}

	natByte(): string { return "(" + String(this.rng.below(256)) + " as uint8)"; }

	natRecord(t: Ty): string {
		return "{ n: " + this.expr(t, 0) + ", k: " + this.natByte() + ", m: " + this.expr(t, 0) + " }";
	}

	natLits(t: Ty, count: int32): string[] {
		const out: string[] = [];
		for (let i = 0; i < count; i++) { out.push(this.literal(t)); }
		return out;
	}

	natArray(t: Ty, lits: string[], xs: string, p: string, indent: string): string {
		const T = tyName(t);
		const list = lits.join(", ");
		if (this.rng.chance(50)) {
			return indent + "let " + xs + ": " + T + "[" + String(lits.length) + "] = [" + list + "];\n" +
				indent + "const " + p + " = " + xs + " as Ptr<" + T + ">;\n";
		}
		return indent + "let " + xs + ": " + T + "[] = [" + list + "];\n" +
			indent + "const " + p + " = " + xs + " as Span<" + T + "> as Ptr<" + T + ">;\n";
	}

	natFloat(): string {
		for (const u of this.tys) { if (u == Ty.Float64) { return this.expr(Ty.Float64, 0); } }
		return this.floatLit();
	}

	natString(): NatText {
		let text = "";
		let bytes = 0;
		const n = this.rng.between(0, 4);
		for (let i = 0; i < n; i++) {
			const piece = STR_CHARS[this.rng.below(STR_CHARS.length)];
			text += piece;
			bytes += utf8Bytes(piece);
		}
		return { text: text, bytes: bytes };
	}

	nativeExpr(t: Ty, depth: int32): string {
		const k = this.pickW(W.NativeRead, W.NativeView);
		if (k == 1) { return this.natSize(t); }
		if (this.bodyDepth > 0) { return ""; }
		return k == 0 ? this.natRead(t, depth) : this.natView(t);
	}

	natSize(t: Ty): string {
		if (!this.reserve(1 as int64)) { return ""; }
		const u = this.pickTy();
		const k = this.rng.below(3);
		if (k == 0) { return "(sizeof " + tyName(u) + " as " + tyName(t) + ")"; }
		const X = this.natStructs(u);
		return "(sizeof " + (k == 1 ? "NatS" : "NatO") + X + " as " + tyName(t) + ")";
	}

	natRead(t: Ty, depth: int32): string {
		if (t == Ty.Uint8 && this.rng.chance(30)) {
			const owners = this.entsAny(EntKind.NatRec).concat(this.entsAny(EntKind.NatRecPtr));
			if (owners.length > 0 && this.reserve(1 as int64)) { return this.pickEnt(owners).name + ".k"; }
		}
		const pool = this.entsOf(EntKind.NatRec, t).concat(this.entsOf(EntKind.NatRef, t)).concat(this.entsOf(EntKind.NatRecPtr, t)).concat(this.entsOf(EntKind.NatPtr, t));
		if (pool.length == 0 || !this.reserve(1 as int64)) { return ""; }
		const e = this.pickEnt(pool);
		if (e.kind == EntKind.NatPtr) {
			const behind = e.cost as int32;
			if (this.rng.chance(50)) { return e.name + "[" + String(this.rng.between(-behind, e.len - 1)) + "]"; }
			this.natIx();
			return e.name + "[ixI(" + this.smallInt(depth) + ", " + String(e.len + behind) + ") - " + String(behind) + "]";
		}
		if (e.kind == EntKind.NatRecPtr) { return e.name + (this.rng.chance(50) ? ".n" : "[].m"); }
		return e.name + (this.rng.chance(50) ? ".n" : ".m");
	}

	natView(t: Ty): string {
		const recs = this.entsOf(EntKind.NatRec, t);
		const ptrs = this.entsOf(EntKind.NatRecPtr, t);
		if (recs.length + ptrs.length == 0 || !this.reserve(2 as int64)) { return ""; }
		const X = tyTitle(t);
		const k = this.rng.below(recs.length + ptrs.length);
		if (k >= recs.length) { return "natGet" + X + "(" + ptrs[k - recs.length].name + ", " + (this.rng.chance(50) ? "true" : "false") + ")"; }
		const r = recs[k].name;
		return this.rng.chance(50) ? "natBorrow" + X + "(" + r + ")" : "natCursor" + X + "(" + r + " as Cursor<NatS" + X + ">)";
	}

	nativeStatement(t: Ty, indent: string, depth: int32): string {
		const k = this.pickW(W.NativePtr, W.NativeSink);
		if (k == 0) { return this.natPtr(t, indent, depth); }
		if (k == 1) { return this.natRef(t, indent, depth); }
		if (k == 2) { return this.natArith(t, indent, depth); }
		if (k == 3) { return this.natHeap(t, indent); }
		if (k == 4) { return this.natLibc(t, indent, depth); }
		if (k == 5) { return this.natCstr(t, indent); }
		if (k == 6) { return this.natOut(t, indent); }
		return this.natSink(t, indent, depth);
	}

	natPtr(t: Ty, indent: string, depth: int32): string {
		const form = this.rng.below(this.atTop && depth == 0 ? 2 : 3);
		if (!this.reserve(14 as int64)) { return ""; }
		const X = this.natStructs(t);
		const S = "NatS" + X;
		const T = tyName(t);
		const n = this.entName("n");
		const z = this.entName("z");
		const a = this.entName("v");
		const b = this.entName("v");
		const through = this.rng.chance(50) ? z + "." : z + "[].";
		const flag = this.rng.chance(50);
		let text = "";
		let owner = n;
		let result = "";
		if (form == 0) {
			const record = this.natRecord(t);
			const kt = this.natByte();
			const av = this.expr(t, 0);
			const bv = this.expr(t, 0);
			text = indent + "let " + n + ": " + S + " = " + record + ";\n" +
				indent + "const " + z + " = " + n + " as Ptr<" + S + ">;\n" +
				indent + "const " + a + ": " + T + " = " + av + ";\n" +
				indent + "const " + b + ": " + T + " = " + bv + ";\n" +
				indent + through + "n = " + a + ";\n" +
				natCheckAt(indent, natSame(t, n + ".n", a), "ptr write") +
				indent + n + ".m = " + b + ";\n" +
				natCheckAt(indent, natSame(t, z + "[].m", b), "ptr owner write") +
				indent + z + ".k = " + kt + ";\n" +
				natCheckAt(indent, n + ".k == " + kt, "ptr byte") +
				natCheckAt(indent, "(sizeof " + S + ") == (3 * sizeof " + T + ")", "ptr layout");
			result = z + "[].m";
		} else if (form == 1) {
			const side = this.rng.chance(50) ? "tail" : "head";
			const other = side == "tail" ? "head" : "tail";
			const h = this.entName("v");
			const hv = this.expr(t, 0);
			const keep = "{ n: " + h + ", k: " + this.natByte() + ", m: " + this.expr(t, 0) + " }";
			const edit = this.natRecord(t);
			const literal = side == "tail" ? "{ head: " + keep + ", tail: " + edit + " }" : "{ head: " + edit + ", tail: " + keep + " }";
			const av = this.expr(t, 0);
			const bv = this.expr(t, 0);
			text = indent + "const " + h + ": " + T + " = " + hv + ";\n" +
				indent + "let " + n + ": NatO" + X + " = " + literal + ";\n" +
				indent + "const " + z + " = " + n + "." + side + " as Ptr<" + S + ">;\n" +
				indent + "const " + a + ": " + T + " = " + av + ";\n" +
				indent + "const " + b + ": " + T + " = " + bv + ";\n" +
				indent + "natPut" + X + "(" + z + ", " + a + ", " + b + ");\n" +
				natCheckAt(indent, natSame(t, n + "." + side + ".n", a), "ptr field") +
				natCheckAt(indent, natSame(t, n + "." + side + ".m", b), "ptr field") +
				natCheckAt(indent, natSame(t, n + "." + other + ".n", h), "ptr neighbour");
			owner = n + "." + side;
			result = "natGet" + X + "(" + z + ", " + (flag ? "true" : "false") + ")";
		} else {
			const count = this.rng.between(2, 3);
			const at = this.rng.below(count);
			const next = (at + 1) % count;
			const h = this.entName("v");
			const hv = this.expr(t, 0);
			let items = "";
			for (let i = 0; i < count; i++) {
				const record = i == next ? "{ n: " + this.expr(t, 0) + ", k: " + this.natByte() + ", m: " + h + " }" : this.natRecord(t);
				items = items == "" ? record : items + ", " + record;
			}
			const av = this.expr(t, 0);
			const bv = this.expr(t, 0);
			const slot = n + "[" + String(at) + "]";
			text = indent + "const " + h + ": " + T + " = " + hv + ";\n" +
				indent + "let " + n + ": " + S + "[] = [" + items + "];\n" +
				indent + "const " + z + " = " + slot + " as Ptr<" + S + ">;\n" +
				indent + "const " + a + ": " + T + " = " + av + ";\n" +
				indent + "const " + b + ": " + T + " = " + bv + ";\n" +
				indent + through + "n = " + a + ";\n" +
				indent + z + "[].m = " + b + ";\n" +
				natCheckAt(indent, natSame(t, slot + ".n", a), "ptr element") +
				natCheckAt(indent, natSame(t, slot + ".m", b), "ptr element") +
				natCheckAt(indent, natSame(t, n + "[" + String(next) + "].m", h), "ptr neighbour");
			owner = slot;
			result = z + ".n";
		}
		this.ents.push({ kind: EntKind.NatRec, name: owner, ty: t, params: [], len: 0, cost: 0 as int64 });
		this.ents.push({ kind: EntKind.NatRecPtr, name: z, ty: t, params: [], len: 0, cost: 0 as int64 });
		return text + this.natResult(t, t, result, indent);
	}

	natRef(t: Ty, indent: string, depth: int32): string {
		if (!this.reserve(12 as int64)) { return ""; }
		const X = this.natStructs(t);
		const S = "NatS" + X;
		const T = tyName(t);
		const n = this.entName("n");
		const m = this.entName("n");
		const a = this.entName("v");
		const b = this.entName("v");
		const record = this.natRecord(t);
		const av = this.expr(t, 0);
		const bv = this.expr(t, 0);
		let text = indent + "const " + n + ": Ref<" + S + "> = " + record + ";\n" +
			indent + "const " + m + " = " + n + ";\n" +
			indent + "const " + a + ": " + T + " = " + av + ";\n" +
			indent + "const " + b + ": " + T + " = " + bv + ";\n" +
			indent + m + ".n = " + a + ";\n" +
			natCheckAt(indent, natSame(t, n + ".n", a), "ref alias") +
			indent + "natRef" + X + "(" + n + ", " + b + ");\n" +
			natCheckAt(indent, natSame(t, m + ".n", b), "ref param") +
			natCheckAt(indent, n + " == " + m, "ref identity");
		if (!(this.atTop && depth == 0)) {
			const r = this.entName("n");
			const c = this.entName("v");
			const cv = this.expr(t, 0);
			text += indent + "const " + c + ": " + T + " = " + cv + ";\n" +
				indent + "let " + r + ": Ref<" + S + ">[] = [" + n + ", " + this.natRecord(t) + "];\n" +
				indent + r + "[1].m = " + c + ";\n" +
				natCheckAt(indent, natSame(t, r + "[1].m", c), "ref element") +
				natCheckAt(indent, "(" + r + "[0] == " + n + ") && (" + r + "[1] != " + n + ")", "ref identity");
		}
		this.ents.push({ kind: EntKind.NatRef, name: n, ty: t, params: [], len: 0, cost: 0 as int64 });
		this.ents.push({ kind: EntKind.NatRef, name: m, ty: t, params: [], len: 0, cost: 0 as int64 });
		return text + this.natResult(t, t, m + ".m", indent);
	}

	natArith(t: Ty, indent: string, depth: int32): string {
		if (this.atTop && depth == 0) { return ""; }
		const count = this.rng.between(3, 6);
		const form = this.rng.below(4);
		if (!this.reserve((2 * count + 14) as int64)) { return ""; }
		const T = tyName(t);
		const xs = this.entName("d");
		const p = this.entName("z");
		const q = this.entName("z");
		const v = this.entName("v");
		let text = "";
		let result = "";
		if (form == 3) {
			const X = this.natStructs(t);
			const S = "NatS" + X;
			const first = this.entName("n");
			const second = this.entName("n");
			const ps = this.entName("d");
			const w = this.entName("v");
			const r1 = this.natRecord(t);
			const r2 = this.natRecord(t);
			const av = this.expr(t, 0);
			const bv = this.expr(t, 0);
			text = indent + "let " + first + ": " + S + " = " + r1 + ";\n" +
				indent + "let " + second + ": " + S + " = " + r2 + ";\n" +
				indent + "let " + ps + ": Ptr<" + S + ">[] = [" + first + " as Ptr<" + S + ">, " + second + " as Ptr<" + S + ">];\n" +
				indent + "const " + p + " = " + ps + " as Span<Ptr<" + S + ">> as Ptr<Ptr<" + S + ">>;\n" +
				indent + "const " + v + ": " + T + " = " + av + ";\n" +
				indent + "const " + w + ": " + T + " = " + bv + ";\n" +
				indent + p + "[1][].n = " + v + ";\n" +
				indent + "(" + p + " + 1)[0].m = " + w + ";\n" +
				natCheckAt(indent, natSame(t, second + ".n", v), "arith pointer array") +
				natCheckAt(indent, natSame(t, second + ".m", w), "arith pointer array") +
				natCheckAt(indent, "((" + p + " + 1) - " + p + ") == 1", "arith pointer array");
			result = second + ".m";
		} else if (form == 0) {
			const k = this.rng.below(count);
			const last = count - 1;
			const lits = this.natLits(t, count);
			const w = this.entName("z");
			const bv = this.expr(t, 0);
			text = this.natArray(t, lits, xs, p, indent) +
				indent + "const " + q + " = " + p + " + " + String(k) + ";\n" +
				natCheckAt(indent, "(" + q + " - " + p + ") == " + String(k), "arith distance") +
				natCheckAt(indent, k > 0 ? p + " < " + q : p + " == " + q, "arith order") +
				natCheckAt(indent, natSame(t, q + "[0]", xs + "[" + String(k) + "]"), "arith read") +
				natCheckAt(indent, natSame(t, "(" + p + " + " + String(last) + ")[0]", xs + "[" + String(last) + "]"), "arith last") +
				(k > 0 ? natCheckAt(indent, natSame(t, q + "[-1]", xs + "[" + String(k - 1) + "]"), "arith back") : "") +
				indent + "let " + w + " = " + p + ";\n" +
				indent + w + " += " + String(k) + ";\n" +
				natCheckAt(indent, w + " == " + q, "arith step") +
				indent + "const " + v + ": " + T + " = " + bv + ";\n" +
				indent + q + "[0] = " + v + ";\n" +
				natCheckAt(indent, natSame(t, xs + "[" + String(k) + "]", v), "arith write");
			this.ents.push({ kind: EntKind.NatPtr, name: p, ty: t, params: [], len: count, cost: 0 as int64 });
			this.ents.push({ kind: EntKind.NatPtr, name: q, ty: t, params: [], len: count - k, cost: k as int64 });
			result = q + "[0]";
		} else if (form == 1) {
			this.natIx();
			const k = this.entName("v");
			const lits = this.natLits(t, count);
			const kv = this.smallInt(0);
			const bv = this.expr(t, 0);
			text = this.natArray(t, lits, xs, p, indent) +
				indent + "const " + k + ": int32 = ixI(" + kv + ", " + String(count) + ");\n" +
				indent + "const " + q + " = " + p + " + " + k + ";\n" +
				natCheckAt(indent, "(" + q + " - " + p + ") == " + k, "arith distance") +
				natCheckAt(indent, "(" + p + " < " + q + ") == (" + k + " > 0)", "arith order") +
				natCheckAt(indent, natSame(t, q + "[0]", xs + "[" + k + "]"), "arith read") +
				natCheckAt(indent, natSame(t, p + "[" + k + "]", xs + "[" + k + "]"), "arith index") +
				indent + "if (" + k + " > 0) { natCheck(" + natSame(t, q + "[-1]", xs + "[" + k + " - 1]") + ", \"arith back\"); }\n" +
				indent + "const " + v + ": " + T + " = " + bv + ";\n" +
				indent + q + "[0] = " + v + ";\n" +
				natCheckAt(indent, natSame(t, xs + "[" + k + "]", v), "arith write");
			result = q + "[0]";
		} else {
			const j = this.entName("j");
			const lits = this.natLits(t, count);
			text = this.natArray(t, lits, xs, p, indent) +
				indent + "let " + q + " = " + p + ";\n" +
				indent + "for (let " + j + ": int32 = 0; " + j + " < " + String(count) + "; " + j + "++) {\n" +
				indent + "\tnatCheck(" + natSame(t, q + "[0]", xs + "[" + j + "]") + ", \"arith walk\");\n" +
				indent + "\t" + q + " += 1;\n" +
				indent + "}\n" +
				natCheckAt(indent, "(" + q + " - " + p + ") == " + String(count), "arith walk");
			result = p + "[" + String(count - 1) + "]";
		}
		this.skipHostLanes();
		return text + this.natResult(t, t, result, indent);
	}

	natHeap(t: Ty, indent: string): string {
		const count = this.rng.between(2, 5);
		const form = this.rng.below(3);
		if (!this.reserve((8 * count + 14) as int64)) { return ""; }
		const T = tyName(t);
		this.natHelpers();
		this.natExtern("natMalloc");
		this.natExtern("natFree");
		const raw = this.entName("n");
		const z = this.entName("z");
		const j = this.entName("j");
		let owner = raw;
		let view = z;
		let size = count;
		let text = "";
		if (form == 1) {
			this.natExtern("natCalloc");
			text = indent + "const " + raw + " = natCalloc(" + String(count) + " as uint64, (sizeof " + T + ") as uint64);\n" +
				indent + "const " + z + " = " + raw + " as Ptr<" + T + ">;\n" +
				natLoop(indent, j, 0, count, "natCheck(" + natSame(t, z + "[" + j + "]", zero(t)) + ", \"heap zeroed\");");
		} else {
			text = indent + "const " + raw + " = natMalloc(" + natBytes(count, T) + ");\n" +
				indent + "const " + z + " = " + raw + " as Ptr<" + T + ">;\n";
		}
		text += natLoop(indent, j, 0, count, z + "[" + j + "] = " + natVal(t, j) + ";") +
			natLoop(indent, j, 0, count, "natCheck(" + natSame(t, z + "[" + j + "]", natVal(t, j)) + ", \"heap fill\");");
		if (form == 2) {
			this.natExtern("natRealloc");
			const grown = this.entName("n");
			const y = this.entName("z");
			text += indent + "const " + grown + " = natRealloc(" + raw + ", " + natBytes(2 * count, T) + ");\n" +
				indent + "const " + y + " = " + grown + " as Ptr<" + T + ">;\n" +
				natLoop(indent, j, 0, count, "natCheck(" + natSame(t, y + "[" + j + "]", natVal(t, j)) + ", \"heap kept\");") +
				natLoop(indent, j, count, 2 * count, y + "[" + j + "] = " + natVal(t, j) + ";") +
				natLoop(indent, j, 0, 2 * count, "natCheck(" + natSame(t, y + "[" + j + "]", natVal(t, j)) + ", \"heap grown\");");
			owner = grown;
			view = y;
			size = 2 * count;
		}
		this.skipHostLanes();
		return text + this.natResult(t, t, view + "[" + String(size - 1) + "]", indent) + indent + "natFree(" + owner + ");\n";
	}

	natLibc(t: Ty, indent: string, depth: int32): string {
		if (this.atTop && depth == 0) { return ""; }
		const count = this.rng.between(2, 5);
		const form = this.rng.below(4);
		if (!this.reserve((4 * count + 14) as int64)) { return ""; }
		const T = tyName(t);
		this.natHelpers();
		const bytes = natBytes(count, T);
		const lits = this.natLits(t, count);
		const xs = this.entName("d");
		const p = this.entName("z");
		const ys = this.entName("d");
		const q = this.entName("z");
		let text = "";
		let result = xs + "[0]";
		if (form == 0) {
			this.natExtern("natMemcpy");
			this.natExtern("natMemcmp");
			const zeros: string[] = [];
			for (let i = 0; i < count; i++) { zeros.push(zero(t)); }
			text = this.natArray(t, lits, xs, p, indent) + this.natArray(t, zeros, ys, q, indent) +
				indent + "natMemcpy(" + q + " as Ptr<void>, " + p + " as Ptr<void>, " + bytes + ");\n";
			for (let i = 0; i < count; i++) { text += natCheckAt(indent, natSame(t, ys + "[" + String(i) + "]", lits[i]), "libc memcpy"); }
			text += natCheckAt(indent, "natMemcmp(" + q + " as Ptr<void>, " + p + " as Ptr<void>, " + bytes + ") == 0", "libc memcmp");
			result = ys + "[" + String(count - 1) + "]";
		} else if (form == 1) {
			this.natExtern("natMemmove");
			const up = this.rng.chance(50);
			const moved = natBytes(count - 1, T);
			text = this.natArray(t, lits, xs, p, indent) +
				indent + (up ? "natMemmove((" + p + " + 1) as Ptr<void>, " + p + " as Ptr<void>, " + moved + ");\n" : "natMemmove(" + p + " as Ptr<void>, (" + p + " + 1) as Ptr<void>, " + moved + ");\n");
			for (let i = 0; i < count; i++) {
				const src = up ? (i == 0 ? 0 : i - 1) : (i == count - 1 ? i : i + 1);
				text += natCheckAt(indent, natSame(t, xs + "[" + String(i) + "]", lits[src]), "libc memmove");
			}
		} else if (form == 2) {
			this.natExtern("natMemset");
			const ones = !isFloat(t) && this.rng.chance(50);
			const expected = !ones ? zero(t) : isSigned(t) ? intLiteral(t, true, 1 as uint64) : maxLiteral(t);
			text = this.natArray(t, lits, xs, p, indent) +
				indent + "natMemset(" + p + " as Ptr<void>, " + (ones ? "255" : "0") + ", " + bytes + ");\n";
			for (let i = 0; i < count; i++) { text += natCheckAt(indent, natSame(t, xs + "[" + String(i) + "]", expected), "libc memset"); }
		} else {
			this.natExtern("natMemcmp");
			this.natSign();
			const at = this.rng.below(count);
			const flip = isFloat(t) ? "(-" + lits[at] + ")" : "(~" + lits[at] + ")";
			const ab = "natMemcmp(" + p + " as Ptr<void>, " + q + " as Ptr<void>, " + bytes + ")";
			const ba = "natMemcmp(" + q + " as Ptr<void>, " + p + " as Ptr<void>, " + bytes + ")";
			text = this.natArray(t, lits, xs, p, indent) + this.natArray(t, lits, ys, q, indent) +
				natCheckAt(indent, ab + " == 0", "libc memcmp equal") +
				indent + q + "[" + String(at) + "] = " + flip + ";\n" +
				natCheckAt(indent, ab + " != 0", "libc memcmp differs") +
				natCheckAt(indent, "natSign(" + ab + ") == (-natSign(" + ba + "))", "libc memcmp antisymmetric");
		}
		this.skipHostLanes();
		return text + this.natResult(t, t, result, indent);
	}

	natCstr(t: Ty, indent: string): string {
		const form = this.rng.below(4);
		if (!this.reserve(12 as int64)) { return ""; }
		this.natHelpers();
		this.natLen();
		const c = this.entName("n");
		const s = this.entName("n");
		const piece = this.natString();
		const literal = "\"" + piece.text + "\"";
		let text = "";
		let result = "natLen(" + c + ")";
		if (form == 0) {
			text = indent + "const " + c + ": cstring = " + literal + ";\n" +
				natCheckAt(indent, "natStrlen(" + c + ") == (" + String(piece.bytes) + " as uint64)", "cstr strlen") +
				natCheckAt(indent, "natLen(" + c + ") == " + String(piece.bytes), "cstr param");
		} else if (form == 1) {
			const digits = String(this.rng.below(100000));
			const joined = this.rng.chance(50);
			const value = joined ? literal + " + String(" + digits + ")" : literal;
			const bytes = joined ? piece.bytes + digits.length : piece.bytes;
			text = indent + "const " + s + ": string = " + value + ";\n" +
				indent + "const " + c + ": cstring = " + s + ";\n" +
				natCheckAt(indent, "natLen(" + s + ") == " + String(bytes), "cstr string") +
				natCheckAt(indent, "(" + c + " as string) == " + s, "cstr back");
		} else if (form == 2) {
			this.natExtern("natAtoi");
			const v = this.entName("v");
			const small = this.smallInt(0);
			text = indent + "const " + v + ": int32 = " + small + " % 100000;\n" +
				indent + "const " + s + ": string = String(" + v + ");\n" +
				natCheckAt(indent, "natAtoi(" + s + ") == " + v, "cstr atoi");
			result = "natAtoi(" + s + ")";
		} else {
			this.natExtern("natStrcmp");
			this.natSign();
			const other = this.natString();
			const o = this.entName("n");
			text = indent + "const " + s + ": string = " + literal + ";\n" +
				indent + "const " + o + ": string = \"" + other.text + "\";\n" +
				natCheckAt(indent, "(natStrcmp(" + s + ", " + o + ") == 0) == (" + s + " == " + o + ")", "cstr strcmp equal") +
				natCheckAt(indent, "natSign(natStrcmp(" + s + ", " + o + ")) == (-natSign(natStrcmp(" + o + ", " + s + ")))", "cstr strcmp antisymmetric") +
				natCheckAt(indent, "natStrcmp(" + s + ", " + s + ") == 0", "cstr strcmp self");
			result = "natSign(natStrcmp(" + s + ", " + o + "))";
		}
		this.skipHostLanes();
		return text + this.natResult(t, Ty.Int32, result, indent);
	}

	natOut(t: Ty, indent: string): string {
		const form = this.rng.below(4);
		if (!this.reserve(14 as int64)) { return ""; }
		this.natHelpers();
		const x = this.entName("v");
		const a = this.entName("v");
		const b = this.entName("v");
		const e = this.entName("v");
		let text = "";
		let result = "";
		let kind = Ty.Float64;
		if (form == 3) {
			this.natExtern("natRandR");
			const seed = "(" + String(this.rng.below(1000)) + " as uint32)";
			text = indent + "let " + x + ": uint32 = " + seed + ";\n" +
				indent + "let " + e + ": uint32 = " + seed + ";\n" +
				indent + "const " + a + " = natRandR(" + x + ");\n" +
				indent + "const " + b + " = natRandR(" + e + ");\n" +
				natCheckAt(indent, "(" + a + " == " + b + ") && (" + x + " == " + e + ") && (" + a + " >= 0)", "out rand_r") +
				natCheckAt(indent, "natRandR(" + x + ") == natRandR(" + e + ")", "out rand_r again");
			result = a;
			kind = Ty.Int32;
		} else {
			const source = this.natFloat();
			text = indent + "const " + x + ": float64 = " + source + ";\n";
			if (form == 0) {
				this.natExtern("natModf");
				text += indent + "let " + e + ": float64 = 0.0;\n" +
					indent + "const " + a + " = natModf(" + x + ", " + e + ");\n" +
					natCheckAt(indent, "natSameF64(" + a + " + " + e + ", " + x + ")", "out modf");
			} else {
				this.natExtern("natLdexp");
				this.natExtern(form == 1 ? "natFrexp" : "natFrexpRef");
				text += indent + "let " + e + ": int32 = " + (form == 1 ? "0" : "3") + ";\n" +
					indent + "const " + a + " = " + (form == 1 ? "natFrexp(" : "natFrexpRef(") + x + ", " + e + ");\n" +
					indent + "if ((" + x + " == " + x + ") && ((" + x + " - " + x + ") == 0.0)) { natCheck(natSameF64(natLdexp(" + a + ", " + e + "), " + x + "), \"out frexp\"); }\n";
			}
			result = a;
		}
		this.skipHostLanes();
		return text + this.natResult(t, kind, result, indent);
	}

	natSink(t: Ty, indent: string, depth: int32): string {
		const form = this.atTop && depth == 0 ? 0 : this.rng.below(2);
		if (!this.reserve(12 as int64)) { return ""; }
		this.natHelpers();
		const n = this.entName("n");
		if (form == 0) {
			const T = tyName(t);
			const z = this.entName("z");
			const lit = this.literal(t);
			this.natExtern("natMalloc");
			this.natExtern("natFreeSink");
			const text = indent + "const " + n + " = natMalloc(" + natBytes(1, T) + ");\n" +
				indent + "const " + z + " = " + n + " as Ptr<" + T + ">;\n" +
				indent + z + "[0] = " + lit + ";\n" +
				natCheckAt(indent, natSame(t, z + "[0]", lit), "sink heap") +
				this.natResult(t, t, z + "[0]", indent) +
				indent + "natFreeSink(" + n + ");\n";
			this.skipHostLanes();
			return text;
		}
		this.natExtern("natPushS");
		const piece = this.natString();
		const s = this.entName("n");
		const text = indent + "let " + n + ": string[] = [];\n" +
			indent + "const " + s + ": string = \"" + piece.text + "\";\n" +
			indent + n + ".natPushS(" + s + ");\n" +
			indent + n + ".natPushS(\"x\" + String(" + n + ".length));\n" +
			natCheckAt(indent, n + ".length == 2", "sink push") +
			natCheckAt(indent, "(" + n + "[0] == \"" + piece.text + "\") && (" + n + "[1] == \"x1\")", "sink push");
		this.skipHostLanes();
		return text + this.natResult(t, Ty.Int32, n + ".length", indent);
	}

	pushEnt(kind: EntKind, name: string, t: Ty, params: Ty[], len: int32, cost: int64): void {
		this.ents.push({ kind: kind, name: name, ty: t, params: params, len: len, cost: cost });
	}

	liveAny(kind: EntKind): Ent[] {
		const out: Ent[] = [];
		if (this.bodyDepth > 0) { return out; }
		for (const e of this.ents) { if (e.kind == kind) { out.push(e); } }
		return out;
	}

	liveOf(kind: EntKind, t: Ty): Ent[] {
		const out: Ent[] = [];
		if (this.bodyDepth > 0) { return out; }
		for (const e of this.ents) { if (e.kind == kind && e.ty == t) { out.push(e); } }
		return out;
	}

	ixHelper(): string {
		return this.useHelper("ixI", "function ixI(i: int32, n: int32): int32 { const r = i % n; return r < 0 ? r + n : r; }\n");
	}

	kit(name: string): string {
		if (name == "swapQ") { return this.useHelper(name, "function swapQ<T>(ref a: T, ref b: T): void { const t = a; a = b; b = t; }\n"); }
		if (name == "fillQ") { return this.useHelper(name, "function fillQ<T>(out o: T, v: T): void { o = v; }\n"); }
		if (name == "takeQ") { return this.useHelper(name, "function takeQ<T>(x: T): T { return x; }\n"); }
		if (name == "roQ") { return this.useHelper(name, "function roQ<T>(readonly x: T): T { return x; }\n"); }
		if (name == "headQ") { return this.useHelper(name, "function headQ<T>(readonly v: Vec<T>, d: T): T { return v.length > 0 ? v[0] : d; }\n"); }
		if (name == "pushQ") { return this.useHelper(name, "function pushQ<T>(ref v: Vec<T>, x: T): void { v.push(x); }\n"); }
		if (name == "readG") { return this.useHelper(name, "function readG<T>(b: Borrow<T>, d: T): T { return b; }\n"); }
		if (name == "firstQ") { return this.useHelper(name, "function firstQ<A, B>(readonly t: [A, B]): A { return t[0]; }\n"); }
		if (name == "swapT") { return this.useHelper(name, "function swapT<A, B>(t: [A, B]): [B, A] { return [t[1], t[0]]; }\n"); }
		if (name == "pairT") { return this.useHelper(name, "function pairT<A, B>(a: A, b: B): [A, B] { return [a, b]; }\n"); }
		if (name == "idQ") { return this.useHelper(name, "function idQ<T>(x: T): T { return x; }\n"); }
		if (name == "ItemQ") {
			return this.useHelper(name, "interface KeyedQ { key: int32; }\n" +
				"class ItemQ<T> implements KeyedQ {\n" +
				"\tkey: int32;\n" +
				"\tv: T;\n" +
				"\tconstructor(k: int32, v: T) { this.key = k; this.v = v; }\n" +
				"}\n" +
				"function bestQ<T extends KeyedQ>(a: T, b: T): T { return a.key >= b.key ? a : b; }\n");
		}
		if (name == "PairQ") {
			return this.useHelper(name, "class PairQ<A, B> {\n" +
				"\ta: A;\n" +
				"\tb: B;\n" +
				"\tconstructor(a: A, b: B) { this.a = a; this.b = b; }\n" +
				"\tswap(): PairQ<B, A> { return new PairQ<B, A>(this.b, this.a); }\n" +
				"\tfirst(): A { return this.a; }\n" +
				"\tsecond(): B { return this.b; }\n" +
				"}\n");
		}
		if (name == "CellQ") {
			this.kit("PairQ");
			return this.useHelper(name, "class CellQ<T> {\n" +
				"\tv: T;\n" +
				"\tconstructor(v: T) { this.v = v; }\n" +
				"\tget(): T { return this.v; }\n" +
				"\tset(x: T): void { this.v = x; }\n" +
				"\tmap<U>(f: (x: T) => U): CellQ<U> { return new CellQ<U>(f(this.v)); }\n" +
				"\tpairWith<U>(u: U): PairQ<T, U> { return new PairQ<T, U>(this.v, u); }\n" +
				"}\n");
		}
		if (name == "StackQ") {
			return this.useHelper(name, "class StackQ<T> {\n" +
				"\titems: T[] = [];\n" +
				"\tpush(x: T): void { this.items.push(x); }\n" +
				"\tsize(): int32 { return this.items.length as int32; }\n" +
				"\ttop(d: T): T { return this.items.length > 0 ? this.items[this.items.length - 1] : d; }\n" +
				"\tdrop(): void { if (this.items.length > 0) { this.items.pop(); } }\n" +
				"}\n");
		}
		if (name == "WrapQ") {
			return this.useHelper(name, "struct WrapQ<T> { v: T; k: int32; }\n" +
				"interface HolderQ<T> { item: T; n: int32; }\n" +
				"function newWrapQ<T>(v: T, k: int32): WrapQ<T> { return { v: v, k: k }; }\n" +
				"function unwrapQ<T>(w: WrapQ<T>): T { return w.v; }\n" +
				"function holdQ<T>(x: T, n: int32): HolderQ<T> { return { item: x, n: n }; }\n");
		}
		unreachable;
	}

	spanHelpers(t: Ty): string {
		const T = tyName(t);
		const X = tyTitle(t);
		this.ixHelper();
		this.useHelper("spanAt" + X, "function spanAt" + X + "(s: Span<" + T + ">, i: int32, d: " + T + "): " + T + " { return s.length > 0 ? s[ixI(i, s.length as int32)] : d; }\n" +
			"function spanSet" + X + "(s: Span<" + T + ">, i: int32, x: " + T + "): void { if (s.length > 0) { s[ixI(i, s.length as int32)] = x; } }\n" +
			"function restV" + X + "(d: " + T + ", ...xs: " + T + "[]): " + T + " { return xs.length > 0 ? xs[xs.length - 1] : d; }\n");
		return X;
	}

	growth(): int32 { return this.mult > (SEQ_LEN_CAP as int64) ? SEQ_LEN_CAP : (this.mult as int32); }

	hasRoom(v: Ent): boolean { return v.len + this.growth() <= SEQ_LEN_CAP; }

	tupleType(params: Ty[]): string {
		let out = "";
		for (const p of params) { out = out == "" ? tyName(p) : out + ", " + tyName(p); }
		return "[" + out + "]";
	}

	tupleEnts(writable: boolean): Ent[] {
		const out: Ent[] = [];
		for (const e of this.ents) {
			if (e.kind == EntKind.TupleVar || (!writable && e.kind == EntKind.TupleFrozen)) { out.push(e); }
		}
		return out;
	}

	componentsOf(e: Ent, t: Ty): int32[] {
		const out: int32[] = [];
		for (let k = 0; k < e.params.length; k++) { if (e.params[k] == t) { out.push(k); } }
		return out;
	}

	tuplesHolding(t: Ty): Ent[] {
		const out: Ent[] = [];
		if (this.bodyDepth > 0) { return out; }
		for (const e of this.tupleEnts(false)) { if (this.componentsOf(e, t).length > 0) { out.push(e); } }
		return out;
	}

	freezeTuple(name: string): void {
		for (let i = 0; i < this.ents.length; i++) {
			if (this.ents[i].name == name) { this.ents[i].kind = EntKind.TupleFrozen; }
		}
	}

	setLen(name: string, len: int32): void {
		for (let i = 0; i < this.ents.length; i++) {
			if (this.ents[i].name == name) { this.ents[i].len = len; }
		}
	}

	seqExpr(t: Ty, depth: int32): string {
		const k = this.pickW(W.SeqElem, W.SeqBorrow);
		if (k == 0) { return this.seqElem(t, depth); }
		if (k == 1) { return this.seqSize(t, depth); }
		if (k == 2) { return this.seqSpan(t, depth); }
		return this.seqBorrow(t, depth);
	}

	vecElem(v: string, t: Ty, depth: int32): string {
		this.ixHelper();
		return "(" + v + ".length > 0 ? " + v + "[ixI(" + this.smallInt(depth) + ", " + v + ".length as int32)] : " + this.elseExpr(t, depth) + ")";
	}

	seqElem(t: Ty, depth: int32): string {
		const tuples = this.tuplesHolding(t);
		const vecs = this.liveOf(EntKind.VecVar, t);
		if (tuples.length > 0 && (vecs.length == 0 || this.rng.chance(50))) {
			const e = this.pickEnt(tuples);
			const at = this.componentsOf(e, t);
			return e.name + "[" + String(at[this.rng.below(at.length)]) + "]";
		}
		if (vecs.length == 0) { return ""; }
		return this.ternary(this.vecElem(this.pickEnt(vecs).name, t, depth));
	}

	seqSize(t: Ty, depth: int32): string {
		const vecs = this.liveAny(EntKind.VecVar);
		if (t == Ty.Int32 && vecs.length > 0) {
			const v = this.pickEnt(vecs);
			const form = this.rng.below(5);
			if (form == 1 && !isFloat(v.ty)) { return "(" + v.name + ".indexOf(" + this.expr(v.ty, depth + 1) + ") as int32)"; }
			if (form == 2) { return v.name + ".join(\",\").length"; }
			if (form == 3) {
				const from = this.rng.below(3);
				return v.name + ".slice(" + String(from) + ", " + String(from + this.rng.below(4)) + ").length";
			}
			if (form == 4) { return v.name + ".concat([" + this.items(v.ty, depth, this.rng.between(1, 2)) + "]).length"; }
			return "(" + v.name + ".length as int32)";
		}
		if (isFloat(t)) { return ""; }
		const owners = this.liveOf(EntKind.VecVar, t);
		if (owners.length == 0) { return ""; }
		const o = this.pickEnt(owners);
		return this.ternary("(" + o.name + ".includes(" + this.expr(t, depth + 1) + ") ? " + this.expr(t, depth + 1) + " : " + this.elseExpr(t, depth) + ")");
	}

	seqSpan(t: Ty, depth: int32): string {
		const vecs = this.liveOf(EntKind.VecVar, t);
		if (vecs.length == 0) { return ""; }
		const X = this.spanHelpers(t);
		const v = this.pickEnt(vecs).name;
		if (this.rng.chance(50)) {
			return "spanAt" + X + "(" + v + ", " + this.smallInt(depth) + ", " + this.expr(t, depth + 1) + ")";
		}
		const lo = this.rng.below(2);
		const hi = lo + this.rng.between(1, 3);
		const view = v + "[" + String(lo) + ".." + String(hi) + "]";
		const text = "(" + v + ".length >= " + String(hi) + " ? spanAt" + X + "(" + view + ", " + this.smallInt(depth) + ", " + this.expr(t, depth + 1) + ") : " + this.elseExpr(t, depth) + ")";
		return this.ternary(text);
	}

	seqBorrow(t: Ty, depth: int32): string {
		const T = tyName(t);
		const tuples = this.tuplesHolding(t);
		const vecs = this.liveOf(EntKind.VecVar, t);
		this.kit("readG");
		if (tuples.length > 0 && (vecs.length == 0 || this.rng.chance(50))) {
			const e = this.pickEnt(tuples);
			const at = this.componentsOf(e, t);
			return "readG<" + T + ">(" + e.name + "[" + String(at[this.rng.below(at.length)]) + "], " + this.expr(t, depth + 1) + ")";
		}
		if (vecs.length > 0 && this.rng.chance(70)) {
			const v = this.pickEnt(vecs).name;
			this.ixHelper();
			const place = v + "[ixI(" + this.smallInt(depth) + ", " + v + ".length as int32)]";
			const text = "(" + v + ".length > 0 ? readG<" + T + ">(" + place + ", " + this.expr(t, depth + 1) + ") : " + this.elseExpr(t, depth) + ")";
			return this.ternary(text);
		}
		const vars = this.visible(t, false);
		if (vars.length == 0) { return ""; }
		return "readG<" + T + ">(" + vars[this.rng.below(vars.length)].name + ", " + this.expr(t, depth + 1) + ")";
	}

	seqStatement(t: Ty, indent: string): string {
		if (!this.reserve(2 as int64)) { return ""; }
		const k = this.pickW(W.SeqTuple, W.SeqLoop);
		if (k == 0) { return this.seqTuple(t, indent); }
		if (k == 1) { return this.seqTupleEdit(t, indent); }
		if (k == 2) { return this.seqVec(t, indent); }
		if (k == 3) { return this.seqVecEdit(t, indent); }
		if (k == 4) { return this.seqSpread(t, indent); }
		if (k == 5) { return this.seqDestruct(t, indent, false); }
		if (k == 6) { return this.seqDestruct(t, indent, true); }
		if (k == 7) { return this.seqSpanSet(t, indent); }
		if (k == 8) { return this.seqRef(t, indent); }
		if (k == 9) { return this.seqMove(t, indent); }
		return this.seqLoop(t, indent);
	}

	seqTuple(t: Ty, indent: string): string {
		const pairs: Ent[] = [];
		for (const e of this.tupleEnts(false)) { if (e.params.length == 2) { pairs.push(e); } }
		const form = this.rng.below(pairs.length > 0 ? 3 : 2);
		if (form == 2) {
			this.kit("swapT");
			const src = this.pickEnt(pairs);
			const A = tyName(src.params[0]);
			const B = tyName(src.params[1]);
			const name = this.entName("n");
			this.pushEnt(EntKind.TupleVar, name, src.params[1], [src.params[1], src.params[0]], 2, 0 as int64);
			return indent + "let " + name + ": [" + B + ", " + A + "] = swapT<" + A + ", " + B + ">(" + src.name + ");\n";
		}
		const params: Ty[] = [t];
		const n = form == 1 ? 2 : this.rng.between(2, 3);
		for (let i = 1; i < n; i++) { params.push(this.pickTy()); }
		let items = "";
		for (const p of params) {
			const e = this.expr(p, 0);
			items = items == "" ? e : items + ", " + e;
		}
		const name = this.entName("n");
		this.pushEnt(EntKind.TupleVar, name, t, params, n, 0 as int64);
		if (form == 1) {
			this.kit("pairT");
			const A = tyName(params[0]);
			const B = tyName(params[1]);
			return indent + "let " + name + ": [" + A + ", " + B + "] = pairT<" + A + ", " + B + ">(" + items + ");\n";
		}
		return indent + "let " + name + ": " + this.tupleType(params) + " = [" + items + "];\n";
	}

	seqTupleEdit(t: Ty, indent: string): string {
		const writable = this.tupleEnts(true);
		const all = this.tupleEnts(false);
		if (all.length == 0) { return this.seqTuple(t, indent); }
		const form = this.rng.below(3);
		if (form == 0 && writable.length > 0) {
			const e = this.pickEnt(writable);
			const k = this.rng.below(e.params.length);
			return indent + e.name + "[" + String(k) + "] = " + this.expr(e.params[k], 0) + ";\n";
		}
		const e = this.pickEnt(all);
		if (form == 1) {
			const n = this.rng.between(1, e.params.length);
			let pattern = "";
			for (let i = 0; i < n; i++) {
				const slot = "l" + String(this.localCount + i) + (this.rng.chance(70) ? " = " + this.expr(e.params[i], 0) : "");
				pattern = pattern == "" ? slot : pattern + ", " + slot;
			}
			for (let i = 0; i < n; i++) { this.newLocal(e.params[i]); }
			return indent + "let [" + pattern + "] = " + e.name + ";\n";
		}
		const name = this.entName("n");
		this.freezeTuple(e.name);
		this.pushEnt(EntKind.TupleFrozen, name, e.ty, e.params, e.params.length, 0 as int64);
		return indent + "let " + name + ": " + this.tupleType(e.params) + " = " + e.name + ";\n";
	}

	newVec(name: string, t: Ty, len: int32): void {
		this.pushEnt(EntKind.VecVar, name, t, [], len, this.blockId as int64);
	}

	seqVec(t: Ty, indent: string): string {
		const T = tyName(t);
		const vecs = this.entsOf(EntKind.VecVar, t);
		const form = this.rng.below(vecs.length > 0 ? 4 : 1);
		if (form == 0) {
			const n = this.rng.below(4);
			const items = this.items(t, -1, n);
			const name = this.entName("v");
			this.newVec(name, t, n);
			return indent + "let " + name + ": Vec<" + T + "> = [" + items + "];\n";
		}
		const src = this.pickEnt(vecs);
		const name = this.entName("v");
		if (form == 1) {
			this.newVec(name, t, src.len);
			return indent + "let " + name + ": Vec<" + T + "> = " + src.name + ";\n";
		}
		if (form == 2) {
			const from = this.rng.below(3);
			this.pushEnt(EntKind.ArrayVar, name, t, [], 0, 0 as int64);
			return indent + "let " + name + ": " + T + "[] = " + src.name + ".slice(" + String(from) + ", " + String(from + this.rng.below(4)) + ");\n";
		}
		const trips = this.rng.between(1, 4);
		const f = this.lambda([t], t, 0, this.spare(trips as int64));
		if (!this.reserve((trips as int64) * f.cost)) { return ""; }
		this.pushEnt(EntKind.ArrayVar, name, t, [], 0, 0 as int64);
		return indent + "let " + name + ": " + T + "[] = " + src.name + ".slice(0, " + String(trips) + ").map(" + f.text + ");\n";
	}

	seqVecEdit(t: Ty, indent: string): string {
		const vecs = this.entsOf(EntKind.VecVar, t);
		if (vecs.length == 0) { return this.seqVec(t, indent); }
		const e = this.pickEnt(vecs);
		const v = e.name;
		let form = this.rng.below(6);
		if (form == 0 && !this.hasRoom(e)) { form = 1; }
		if (form == 0) {
			const value = this.expr(t, 0);
			this.setLen(v, e.len + this.growth());
			return indent + v + ".push(" + value + ");\n";
		}
		const guard = indent + "if (" + v + ".length > 0) { ";
		if (form == 1) {
			this.ixHelper();
			return guard + v + "[ixI(" + this.smallInt(0) + ", " + v + ".length as int32)] = " + this.expr(t, 0) + "; }\n";
		}
		if (form == 2) { return guard + v + ".pop(); }\n"; }
		if (form == 3) {
			this.ixHelper();
			return guard + v + ".splice(ixI(" + this.smallInt(0) + ", " + v + ".length as int32), 1); }\n";
		}
		if (form == 4) { return indent + v + ".fill(" + this.expr(t, 0) + ");\n"; }
		const n = String(this.rng.below(4));
		return indent + "if (" + v + ".length > " + n + ") { " + v + ".setLength(" + n + "); }\n";
	}

	seqSpread(t: Ty, indent: string): string {
		const T = tyName(t);
		const vecs = this.entsOf(EntKind.VecVar, t);
		if (vecs.length == 0) { return this.seqVec(t, indent); }
		const a = this.pickEnt(vecs);
		const b = this.pickEnt(vecs);
		const form = this.rng.below(4);
		if (form == 3) {
			const X = this.spanHelpers(t);
			const d = this.expr(t, 0);
			const name = this.newLocal(t);
			return indent + "let " + name + ": " + T + " = restV" + X + "(" + d + ", ..." + a.name + ");\n";
		}
		if (form == 2) {
			const name = this.entName("a");
			this.pushEnt(EntKind.ArrayVar, name, t, [], 0, 0 as int64);
			return indent + "let " + name + ": " + T + "[] = [..." + a.name + ", " + this.expr(t, 0) + "];\n";
		}
		const joined = form == 1 ? a.len + b.len + 1 : a.len + 1;
		if (joined > SEQ_LEN_CAP) { return this.seqVec(t, indent); }
		const value = form == 1 ? "[" + this.expr(t, 0) + ", ..." + a.name + ", ..." + b.name + "]" : "[..." + a.name + ", " + this.expr(t, 0) + "]";
		const name = this.entName("v");
		this.newVec(name, t, joined);
		return indent + "let " + name + ": Vec<" + T + "> = " + value + ";\n";
	}

	seqDestruct(t: Ty, indent: string, rest: boolean): string {
		const vecs = this.entsOf(EntKind.VecVar, t);
		if (vecs.length == 0) { return this.seqVec(t, indent); }
		const src = this.pickEnt(vecs);
		const n = this.rng.between(1, 3);
		let pattern = "";
		for (let i = 0; i < n; i++) {
			const slot = "l" + String(this.localCount + i) + " = " + this.expr(t, 0);
			pattern = pattern == "" ? slot : pattern + ", " + slot;
		}
		for (let i = 0; i < n; i++) { this.newLocal(t); }
		if (rest) {
			const tail = this.entName("v");
			this.newVec(tail, t, src.len);
			pattern += ", ..." + tail;
			this.directive("// @skip-raiser: the Raiser has no host bridge for msGenericArrayPush, so an array pattern with a rest element stops (inbox/compiler/2026-10-17-raiser-has-no-host-bridge-for-msgenericarraypush)");
		}
		return indent + "let [" + pattern + "] = " + src.name + ";\n";
	}

	seqSpanSet(t: Ty, indent: string): string {
		const vecs = this.entsOf(EntKind.VecVar, t);
		if (vecs.length == 0) { return this.seqVec(t, indent); }
		const X = this.spanHelpers(t);
		const v = this.pickEnt(vecs).name;
		if (this.rng.chance(50)) { return indent + "spanSet" + X + "(" + v + ", " + this.smallInt(0) + ", " + this.expr(t, 0) + ");\n"; }
		const lo = this.rng.below(2);
		const hi = lo + this.rng.between(1, 3);
		return indent + "if (" + v + ".length >= " + String(hi) + ") { spanSet" + X + "(" + v + "[" + String(lo) + ".." + String(hi) + "], " + this.smallInt(0) + ", " + this.expr(t, 0) + "); }\n";
	}

	seqRef(t: Ty, indent: string): string {
		const T = tyName(t);
		const vecs = this.entsOf(EntKind.VecVar, t);
		const writable = this.tupleEnts(true);
		const form = this.rng.below(7);
		if (form == 0 && vecs.length > 0) {
			const e = this.pickEnt(vecs);
			if (this.hasRoom(e)) {
				this.kit("pushQ");
				const value = this.expr(t, 0);
				this.setLen(e.name, e.len + this.growth());
				return indent + "pushQ<" + T + ">(" + e.name + ", " + value + ");\n";
			}
		}
		if (form == 1 && vecs.length > 1) {
			const a = this.pickEnt(vecs);
			const b = this.pickEnt(vecs);
			if (a.name != b.name) {
				this.kit("swapQ");
				const bound = a.len > b.len ? a.len : b.len;
				this.setLen(a.name, bound);
				this.setLen(b.name, bound);
				return indent + "swapQ<Vec<" + T + ">>(" + a.name + ", " + b.name + ");\n";
			}
		}
		if (form == 2) {
			const vars = this.visible(t, true);
			if (vars.length > 1) {
				const a = vars[this.rng.below(vars.length)].name;
				const b = vars[this.rng.below(vars.length)].name;
				if (a != b) {
					this.kit("swapQ");
					return indent + "swapQ<" + T + ">(" + a + ", " + b + ");\n";
				}
			}
		}
		if (form == 3 && vecs.length > 0) {
			const e = this.pickEnt(vecs);
			const n = this.rng.below(4);
			this.kit("fillQ");
			const items = this.items(t, -1, n);
			if (n > e.len) { this.setLen(e.name, n); }
			return indent + "fillQ<Vec<" + T + ">>(out " + e.name + ", [" + items + "]);\n";
		}
		if (form == 4 && writable.length > 0) {
			const e = this.pickEnt(writable);
			let items = "";
			for (const p of e.params) {
				const x = this.expr(p, 0);
				items = items == "" ? x : items + ", " + x;
			}
			this.kit("fillQ");
			return indent + "fillQ<" + this.tupleType(e.params) + ">(out " + e.name + ", [" + items + "]);\n";
		}
		if (form == 5 && writable.length > 1) {
			const a = this.pickEnt(writable);
			const b = this.pickEnt(writable);
			if (a.name != b.name && this.tupleType(a.params) == this.tupleType(b.params)) {
				this.kit("swapQ");
				return indent + "swapQ<" + this.tupleType(a.params) + ">(" + a.name + ", " + b.name + ");\n";
			}
		}
		if (form == 6) {
			const pairs: Ent[] = [];
			for (const e of this.tupleEnts(false)) { if (e.params.length == 2) { pairs.push(e); } }
			if (pairs.length > 0 && this.rng.chance(50)) {
				const e = this.pickEnt(pairs);
				this.kit("firstQ");
				const name = this.newLocal(e.params[0]);
				return indent + "let " + name + ": " + tyName(e.params[0]) + " = firstQ<" + tyName(e.params[0]) + ", " + tyName(e.params[1]) + ">(" + e.name + ");\n";
			}
			if (vecs.length > 0) {
				this.kit("headQ");
				const e = this.pickEnt(vecs);
				const d = this.expr(t, 0);
				const name = this.newLocal(t);
				return indent + "let " + name + ": " + T + " = headQ<" + T + ">(" + e.name + ", " + d + ");\n";
			}
		}
		return this.seqVec(t, indent);
	}

	seqMove(t: Ty, indent: string): string {
		const T = tyName(t);
		const movable: Ent[] = [];
		for (const e of this.entsOf(EntKind.VecVar, t)) { if (e.cost == (this.blockId as int64)) { movable.push(e); } }
		if (movable.length == 0) { return this.seqVec(t, indent); }
		const m = this.pickEnt(movable);
		this.dropEnt(m.name);
		this.kit("takeQ");
		if (this.rng.chance(50)) {
			const name = this.entName("v");
			this.newVec(name, t, m.len);
			return indent + "let " + name + ": Vec<" + T + "> = takeQ<Vec<" + T + ">>(move " + m.name + ");\n";
		}
		this.kit("CellQ");
		this.kit("headQ");
		const cell = this.entName("c");
		const seed = this.expr(t, 0);
		const d = this.expr(t, 0);
		const name = this.newLocal(t);
		return indent + "const " + cell + " = new CellQ<Vec<" + T + ">>([" + seed + "]);\n" +
			indent + cell + ".set(move " + m.name + ");\n" +
			indent + "let " + name + ": " + T + " = headQ<" + T + ">(" + cell + ".get(), " + d + ");\n";
	}

	seqLoop(t: Ty, indent: string): string {
		const vecs = this.entsOf(EntKind.VecVar, t);
		if (vecs.length == 0) { return this.seqVec(t, indent); }
		return this.collLoop(t, this.pickEnt(vecs).name, indent);
	}

	gclsExpr(t: Ty, depth: int32): string {
		const k = this.pickW(W.GclsCell, W.GclsWrap);
		if (k == 0) { return this.gclsCell(t, depth); }
		if (k == 1) { return this.gclsMap(t, depth); }
		if (k == 2) { return this.gclsNest(t, depth); }
		if (k == 3) { return this.gclsPair(t, depth); }
		if (k == 4) { return this.gclsStack(t, depth); }
		if (k == 5) { return this.gclsBest(t, depth); }
		return this.gclsWrap(t, depth);
	}

	gclsCell(t: Ty, depth: int32): string {
		const T = tyName(t);
		this.kit("CellQ");
		const cells = this.liveOf(EntKind.CellVar, t);
		const form = this.rng.below(4);
		if (form == 0 && cells.length > 0) {
			const c = this.pickEnt(cells).name;
			return this.rng.chance(50) ? c + ".get()" : c + ".v";
		}
		if (form == 1 && cells.length > 0) {
			this.kit("idQ");
			return "idQ(" + this.pickEnt(cells).name + ").get()";
		}
		if (form == 2) {
			this.kit("idQ");
			return "idQ<CellQ<" + T + ">>(new CellQ<" + T + ">(" + this.expr(t, depth + 1) + ")).get()";
		}
		return "new CellQ<" + T + ">(" + this.expr(t, depth + 1) + ").get()";
	}

	gclsMap(t: Ty, depth: int32): string {
		const T = tyName(t);
		this.kit("CellQ");
		const u = this.pickTy();
		const f = this.lambda([u], t, depth, this.spare(1 as int64));
		if (!this.reserve(f.cost)) { return ""; }
		const cells = this.liveOf(EntKind.CellVar, u);
		if (cells.length > 0 && this.rng.chance(60)) {
			return this.pickEnt(cells).name + ".map<" + T + ">(" + f.text + ").get()";
		}
		return "new CellQ<" + tyName(u) + ">(" + this.expr(u, depth + 1) + ").map<" + T + ">(" + f.text + ").get()";
	}

	gclsNest(t: Ty, depth: int32): string {
		const T = tyName(t);
		this.kit("CellQ");
		const nests = this.liveOf(EntKind.NestVar, t);
		const form = this.rng.below(3);
		if (form == 0 && nests.length > 0) {
			const n = this.pickEnt(nests).name;
			return this.rng.chance(50) ? n + ".get().get()" : n + ".v.v";
		}
		const inner = "new CellQ<" + T + ">(" + this.expr(t, depth + 1) + ")";
		if (form == 2) { return "new CellQ<CellQ<CellQ<" + T + ">>>(new CellQ<CellQ<" + T + ">>(" + inner + ")).v.v.v"; }
		return "new CellQ<CellQ<" + T + ">>(" + inner + ").get().get()";
	}

	gclsPair(t: Ty, depth: int32): string {
		const T = tyName(t);
		this.kit("CellQ");
		const pairs: Ent[] = [];
		for (const e of this.ents) {
			if (e.kind == EntKind.PairVar && this.bodyDepth == 0 && this.componentsOf(e, t).length > 0) { pairs.push(e); }
		}
		const form = this.rng.below(3);
		if (form == 0 && pairs.length > 0) {
			const p = this.pickEnt(pairs);
			const at = this.componentsOf(p, t);
			const first = at[this.rng.below(at.length)] == 0;
			const swapped = this.rng.chance(40);
			if (swapped) { return p.name + ".swap()." + (first ? "second()" : "first()"); }
			return p.name + (first ? (this.rng.chance(50) ? ".a" : ".first()") : (this.rng.chance(50) ? ".b" : ".second()"));
		}
		const u = this.pickTy();
		const U = tyName(u);
		if (form == 1) { return "new PairQ<" + U + ", " + T + ">(" + this.expr(u, depth + 1) + ", " + this.expr(t, depth + 1) + ").swap().first()"; }
		return "new CellQ<" + T + ">(" + this.expr(t, depth + 1) + ").pairWith<" + U + ">(" + this.expr(u, depth + 1) + ").first()";
	}

	gclsStack(t: Ty, depth: int32): string {
		const T = tyName(t);
		this.kit("StackQ");
		const stacks = this.liveOf(EntKind.StackVar, t);
		if (t == Ty.Int32 && this.rng.chance(40)) {
			const any = this.liveAny(EntKind.StackVar);
			if (any.length > 0) { return this.pickEnt(any).name + ".size()"; }
		}
		if (stacks.length > 0) { return this.pickEnt(stacks).name + ".top(" + this.expr(t, depth + 1) + ")"; }
		return "new StackQ<" + T + ">().top(" + this.expr(t, depth + 1) + ")";
	}

	gclsBest(t: Ty, depth: int32): string {
		const T = tyName(t);
		this.kit("ItemQ");
		const items = this.liveOf(EntKind.ItemVar, t);
		if (items.length > 1 && this.rng.chance(60)) {
			const a = this.pickEnt(items).name;
			const b = this.pickEnt(items).name;
			if (a != b) {
				const field = t == Ty.Int32 && this.rng.chance(30) ? ".key" : ".v";
				return this.rng.chance(50) ? "bestQ(" + a + ", " + b + ")" + field : "bestQ<ItemQ<" + T + ">>(" + b + ", " + a + ")" + field;
			}
		}
		const left = "new ItemQ<" + T + ">(" + String(this.rng.below(6)) + ", " + this.expr(t, depth + 1) + ")";
		const right = "new ItemQ<" + T + ">(" + String(this.rng.below(6)) + ", " + this.expr(t, depth + 1) + ")";
		return "bestQ<ItemQ<" + T + ">>(" + left + ", " + right + ").v";
	}

	gclsWrap(t: Ty, depth: int32): string {
		const T = tyName(t);
		this.kit("WrapQ");
		const form = this.rng.below(4);
		if (form == 0) { return "unwrapQ<" + T + ">(newWrapQ<" + T + ">(" + this.expr(t, depth + 1) + ", " + this.smallInt(depth) + "))"; }
		if (form == 1) {
			const inner = "newWrapQ<" + T + ">(" + this.expr(t, depth + 1) + ", " + this.smallInt(depth) + ")";
			return "unwrapQ<" + T + ">(unwrapQ<WrapQ<" + T + ">>(newWrapQ<WrapQ<" + T + ">>(" + inner + ", " + this.smallInt(depth) + ")))";
		}
		if (form == 2) {
			if (t == Ty.Int32 && this.rng.chance(40)) { return "holdQ<" + T + ">(" + this.expr(t, depth + 1) + ", " + this.smallInt(depth) + ").n"; }
			return "holdQ<" + T + ">(" + this.expr(t, depth + 1) + ", " + this.smallInt(depth) + ").item";
		}
		const inner = "newWrapQ<" + T + ">(" + this.expr(t, depth + 1) + ", " + this.smallInt(depth) + ")";
		return "holdQ<WrapQ<" + T + ">>(" + inner + ", " + this.smallInt(depth) + ").item.v";
	}

	gclsStatement(t: Ty, indent: string): string {
		if (!this.reserve(3 as int64)) { return ""; }
		const k = this.pickW(W.GclsDecl, W.GclsOwn);
		if (k == 0) { return this.gclsDecl(t, indent); }
		if (k == 1) { return this.gclsSet(t, indent); }
		if (k == 2) { return this.gclsRef(t, indent); }
		return this.gclsOwn(t, indent);
	}

	gclsDecl(t: Ty, indent: string): string {
		const T = tyName(t);
		const form = this.rng.below(5);
		if (form == 0) {
			this.kit("CellQ");
			const value = this.expr(t, 0);
			const name = this.entName("c");
			this.pushEnt(EntKind.CellVar, name, t, [], 0, 0 as int64);
			return indent + "let " + name + " = new CellQ<" + T + ">(" + value + ");\n";
		}
		if (form == 1) {
			this.kit("CellQ");
			const value = this.expr(t, 0);
			const name = this.entName("n");
			this.pushEnt(EntKind.NestVar, name, t, [], 0, 0 as int64);
			return indent + "let " + name + " = new CellQ<CellQ<" + T + ">>(new CellQ<" + T + ">(" + value + "));\n";
		}
		if (form == 2) {
			this.kit("PairQ");
			const u = this.pickTy();
			const a = this.expr(t, 0);
			const b = this.expr(u, 0);
			const name = this.entName("z");
			this.pushEnt(EntKind.PairVar, name, t, [t, u], 0, 0 as int64);
			return indent + "const " + name + " = new PairQ<" + T + ", " + tyName(u) + ">(" + a + ", " + b + ");\n";
		}
		if (form == 3) {
			this.kit("StackQ");
			const value = this.expr(t, 0);
			const name = this.entName("s");
			this.pushEnt(EntKind.StackVar, name, t, [], 1, 0 as int64);
			return indent + "const " + name + " = new StackQ<" + T + ">();\n" + indent + name + ".push(" + value + ");\n";
		}
		this.kit("ItemQ");
		const value = this.expr(t, 0);
		const name = this.entName("k");
		this.pushEnt(EntKind.ItemVar, name, t, [], 0, 0 as int64);
		return indent + "const " + name + " = new ItemQ<" + T + ">(" + String(this.rng.below(6)) + ", " + value + ");\n";
	}

	gclsSet(t: Ty, indent: string): string {
		const held: Ent[] = [];
		for (const e of this.ents) {
			if (e.kind == EntKind.CellVar || e.kind == EntKind.NestVar || e.kind == EntKind.PairVar || e.kind == EntKind.StackVar || e.kind == EntKind.ItemVar) { held.push(e); }
		}
		if (held.length == 0) { return this.gclsDecl(t, indent); }
		const e = this.pickEnt(held);
		const T = tyName(e.ty);
		const n = e.name;
		if (e.kind == EntKind.CellVar) {
			return this.rng.chance(50) ? indent + n + ".set(" + this.expr(e.ty, 0) + ");\n" : indent + n + ".v = " + this.expr(e.ty, 0) + ";\n";
		}
		if (e.kind == EntKind.NestVar) {
			const form = this.rng.below(3);
			if (form == 0) { return indent + n + ".get().set(" + this.expr(e.ty, 0) + ");\n"; }
			if (form == 1) { return indent + n + ".v.v = " + this.expr(e.ty, 0) + ";\n"; }
			return indent + n + ".set(new CellQ<" + T + ">(" + this.expr(e.ty, 0) + "));\n";
		}
		if (e.kind == EntKind.PairVar) {
			const second = this.rng.chance(50);
			return indent + n + (second ? ".b = " : ".a = ") + this.expr(e.params[second ? 1 : 0], 0) + ";\n";
		}
		if (e.kind == EntKind.StackVar) {
			if (this.rng.chance(30)) { return indent + n + ".drop();\n"; }
			if (e.len + this.growth() > SEQ_LEN_CAP) { return indent + n + ".drop();\n"; }
			const value = this.expr(e.ty, 0);
			this.setLen(n, e.len + this.growth());
			return indent + n + ".push(" + value + ");\n";
		}
		return indent + n + ".v = " + this.expr(e.ty, 0) + ";\n";
	}

	gclsRef(t: Ty, indent: string): string {
		const T = tyName(t);
		const cells = this.entsOf(EntKind.CellVar, t);
		const form = this.rng.below(4);
		if (form == 0 && cells.length > 1) {
			const a = this.pickEnt(cells).name;
			const b = this.pickEnt(cells).name;
			if (a != b) {
				this.kit("swapQ");
				return indent + "swapQ<" + T + ">(" + a + ".v, " + b + ".v);\n";
			}
		}
		if (form == 1 && cells.length > 1) {
			const a = this.pickEnt(cells).name;
			const b = this.pickEnt(cells).name;
			if (a != b) {
				this.kit("swapQ");
				return indent + "swapQ<CellQ<" + T + ">>(" + a + ", " + b + ");\n";
			}
		}
		if (form == 2) {
			this.kit("fillQ");
			const value = this.expr(t, 0);
			const name = this.newLocal(t);
			return indent + "let " + name + ": " + T + ";\n" + indent + "fillQ<" + T + ">(out " + name + ", " + value + ");\n";
		}
		if (form == 3 && cells.length > 0) {
			this.kit("roQ");
			const name = this.newLocal(t);
			return indent + "let " + name + ": " + T + " = roQ<CellQ<" + T + ">>(" + this.pickEnt(cells).name + ").get();\n";
		}
		return this.gclsDecl(t, indent);
	}

	gclsOwn(t: Ty, indent: string): string {
		const T = tyName(t);
		const X = this.ownHelpers(t);
		const O = "Own" + X;
		this.kit("swapQ");
		this.kit("takeQ");
		const form = this.rng.below(3);
		const a = this.entName("z");
		const b = this.entName("z");
		const first = this.expr(t, 0);
		const second = this.expr(t, 0);
		const head = indent + "let " + a + ": " + O + " = mkO" + X + "(" + first + ", \"a\");\n" +
			indent + "let " + b + ": " + O + " = mkO" + X + "(" + second + ", \"b\");\n";
		const swap = this.rng.chance(50) ? indent + "swapQ<" + O + ">(" + a + ", " + b + ");\n" : "";
		const name = this.newLocal(t);
		if (form == 0) {
			this.kit("StackQ");
			const s = this.entName("s");
			return indent + "const " + s + " = new StackQ<" + O + ">();\n" + head + swap +
				indent + s + ".push(move " + a + ");\n" +
				indent + s + ".push(" + b + ");\n" +
				indent + "let " + name + ": " + T + " = " + s + ".top(" + b + ").v;\n" +
				indent + s + ".drop();\n";
		}
		if (form == 1) {
			this.kit("CellQ");
			const c = this.entName("c");
			return head + swap +
				indent + "const " + c + " = new CellQ<" + O + ">(" + b + ");\n" +
				indent + c + ".set(move " + a + ");\n" +
				indent + "let " + name + ": " + T + " = " + c + ".get().v;\n";
		}
		const r = this.entName("z");
		return head + swap +
			indent + "let " + r + ": " + O + " = takeQ<" + O + ">(move " + a + ");\n" +
			indent + "let " + name + ": " + T + " = " + r + ".v;\n";
	}

	hasHelper(name: string): boolean {
		for (const n of this.helperNames) { if (n == name) { return true; } }
		return false;
	}

	lift(x: string, t: Ty): string {
		if (t == Ty.Int32) { return x; }
		if (!isFloat(t) && !isSigned(t)) { return this.wrapHelper(Ty.Int32, t) + "(" + x + ")"; }
		if (fitsRaw(Ty.Int32, t)) { return "(" + x + " as " + tyName(t) + ")"; }
		return this.convHelper(Ty.Int32, t) + "(" + x + ")";
	}

	member(et: ETy): string { return et.name + ".M" + String(this.rng.below(et.n)); }

	members(et: ETy, from: int32, to: int32): string {
		let out = "";
		for (let j = from; j < to; j++) { out += (out == "" ? "" : " | ") + et.name + ".M" + String(j); }
		return out;
	}

	enumVars(et: ETy): Ent[] {
		const out: Ent[] = [];
		for (const e of this.ents) { if (e.kind == EntKind.EnumVar && e.len == et.id) { out.push(e); } }
		return out;
	}

	enumType(shape: EShape): ETy {
		const pool: ETy[] = [];
		for (const e of this.eTypes) { if (e.shape == shape) { pool.push(e); } }
		if (pool.length >= 3 || (pool.length > 0 && this.rng.chance(60))) { return pool[this.rng.below(pool.length)]; }
		this.ixHelper();
		const id = this.eTypes.length;
		if (shape == EShape.Bitset) { return this.flagType(id, pool.length); }
		if (shape == EShape.Literal) { return this.literalType(id, pool.length); }
		return this.numericType(id, pool.length);
	}

	numericType(id: int32, k: int32): ETy {
		const name = "En" + String(k);
		const n = this.rng.between(2, 6);
		const vals: int32[] = [];
		let expected = 0;
		for (let j = 0; j < n; j++) {
			let v = expected;
			if (j == 0 && this.rng.chance(25)) {
				v = this.rng.between(-6, -1);
			} else if (this.rng.chance(35)) {
				v = expected + this.rng.between(1, 5);
			}
			vals.push(v);
			expected = v + 1;
		}
		const shuffled = n >= 3 && this.rng.chance(25);
		if (shuffled) {
			const tmp = vals[0];
			vals[0] = vals[n - 1];
			vals[n - 1] = tmp;
		}
		let members = "";
		expected = 0;
		for (let j = 0; j < n; j++) {
			const implicit = !shuffled && vals[j] == expected;
			members += "\tM" + String(j) + (implicit ? "" : " = " + String(vals[j])) + ",\n";
			expected = vals[j] + 1;
		}
		let at = "function at" + name + "(i: int32): " + name + " {\n\tconst r = ixI(i, " + String(n) + ");\n";
		for (let j = 0; j < n - 1; j++) { at += "\tif (r == " + String(j) + ") { return " + name + ".M" + String(j) + "; }\n"; }
		at += "\treturn " + name + ".M" + String(n - 1) + ";\n}\n";
		this.useHelper(name, "enum " + name + " {\n" + members + "}\n" + at);
		const et: ETy = { id: id, shape: EShape.Numeric, name: name, ann: name, n: n, lits: [] };
		this.eTypes.push(et);
		return et;
	}

	flagType(id: int32, k: int32): ETy {
		const name = "Fg" + String(k);
		const n = FLAG_COUNTS[this.rng.below(FLAG_COUNTS.length)];
		let members = "";
		for (let j = 0; j < n; j++) { members += (j == 0 ? "" : ", ") + "M" + String(j); }
		const B = "BitSet<" + name + ">";
		const last = name + ".M" + String(n - 1);
		let raw = "\treturn m.size() as int32;\n";
		if (n <= 32) {
			raw = "\treturn ((m as uint32) % (251 as uint32)) as int32;\n";
		} else if (n <= 64) {
			raw = "\treturn ((m as uint64) % (251 as uint64)) as int32;\n";
		}
		this.useHelper(name, "enum " + name + " { " + members + " }\n" +
			"function bs" + name + "(a: " + B + ", b: " + B + ", f: int32): int32 {\n" +
			"\tconst m = a | b;\n" +
			"\tif (f == 0) { return (a & b).size() as int32; }\n" +
			"\tif (f == 1) { return m.size() as int32; }\n" +
			"\tif (f == 2) { return (a ^ b).size() as int32; }\n" +
			"\tif (f == 3) { return a.difference(b).size() as int32; }\n" +
			"\tif (f == 4) {\n" +
			"\t\tif (a.isSubsetOf(b)) { return 1; }\n" +
			"\t\tif (a.isDisjointFrom(b)) { return 2; }\n" +
			"\t\treturn 3;\n" +
			"\t}\n" +
			"\tif (f == 5) {\n" +
			"\t\tif (a == b) { return 4; }\n" +
			"\t\tif (a.has(" + name + ".M0)) { return 5; }\n" +
			"\t\tif (b.has(" + name + ".M0)) { return 6; }\n" +
			"\t\treturn 7;\n" +
			"\t}\n" +
			"\tif (f == 6) {\n" +
			"\t\tlet s: int32 = 0;\n" +
			"\t\tfor (const x of m) { s += x as int32; }\n" +
			"\t\treturn s;\n" +
			"\t}\n" +
			"\tif (f == 7) { return (a.excl(" + name + ".M0).size() as int32) * 100 + (b.incl(" + last + ").size() as int32); }\n" +
			raw + "}\n");
		const et: ETy = { id: id, shape: EShape.Bitset, name: name, ann: B, n: n, lits: [] };
		this.eTypes.push(et);
		return et;
	}

	literalType(id: int32, k: int32): ETy {
		const name = "Lt" + String(k);
		const lits = LIT_SETS[k].split(",");
		const n = lits.length;
		let union = "";
		for (let j = 0; j < n; j++) { union += (j == 0 ? "" : " | ") + quoted(lits[j]); }
		let at = "function at" + name + "(i: int32): " + name + " {\n\tconst r = ixI(i, " + String(n) + ");\n";
		let next = "function next" + name + "(d: " + name + "): " + name + " {\n";
		let ifc = "function if" + name + "(d: " + name + ", a: int32, b: int32): int32 {\n";
		let mx = "function mx" + name + "(d: " + name + ", a: int32, b: int32): int32 {\n\treturn match (d) {\n";
		for (let j = 0; j < n; j++) {
			const pick = j % 2 == 0 ? "a" : "b";
			if (j < n - 1) {
				at += "\tif (r == " + String(j) + ") { return " + quoted(lits[j]) + "; }\n";
				next += "\tif (d == " + quoted(lits[j]) + ") { return " + quoted(lits[j + 1]) + "; }\n";
				ifc += "\tif (d " + (j % 2 == 0 ? "===" : "==") + " " + quoted(lits[j]) + ") { return " + pick + "; }\n";
			}
			mx += "\t\t" + quoted(lits[j]) + " => " + pick + ",\n";
		}
		at += "\treturn " + quoted(lits[n - 1]) + ";\n}\n";
		next += "\treturn " + quoted(lits[0]) + ";\n}\n";
		ifc += "\treturn b;\n}\n";
		mx += "\t};\n}\n";
		const mw = "function mw" + name + "(d: " + name + ", a: int32, b: int32): int32 {\n\treturn match (d) {\n\t\t" + quoted(lits[0]) + " => a,\n\t\t_ => b,\n\t};\n}\n";
		const cmp = "function cmp" + name + "(d: " + name + ", e: " + name + ", form: int32): int32 {\n" +
			"\tif (form == 0) { if (d == " + quoted(lits[0]) + ") { return 1; } return 2; }\n" +
			"\tif (form == 1) { if (d != " + quoted(lits[1]) + ") { return 3; } return 4; }\n" +
			"\tif (form == 2) { if (d === " + quoted(lits[n - 1]) + ") { return 5; } return 6; }\n" +
			"\tconst s: string = d;\n" +
			"\tconst u: string = e;\n" +
			"\tif (s == u) { return s.length; }\n" +
			"\treturn u.length + 10;\n}\n";
		this.useHelper(name, "type " + name + " = " + union + ";\n" + at + next + ifc + mx + mw + cmp);
		const et: ETy = { id: id, shape: EShape.Literal, name: name, ann: name, n: n, lits: lits };
		this.eTypes.push(et);
		return et;
	}

	enumKit(shape: EShape, variant: int32): ETy {
		for (const e of this.eTypes) { if (e.shape == shape && e.n == variant) { return e; } }
		this.ixHelper();
		const id = this.eTypes.length;
		if (shape == EShape.Distinct) { return this.distinctKit(id, variant); }
		if (shape == EShape.Disc) { return this.discKit(id, variant); }
		return this.unknownKit(id);
	}

	distinctKit(id: int32, variant: int32): ETy {
		const isInt = variant == 0;
		const name = isInt ? "DsI" : "DsF";
		const s = isInt ? "I" : "F";
		const ctor = isInt ? "(ixI(i, 2000) - 1000) as DsI" : "((ixI(i, 2000) - 1000) as float64 * 0.5) as DsF";
		const tail = isInt ? "\treturn (x as int32) + n;\n" : "\treturn (((x as float64) * 2.0) as int32) + n;\n";
		this.useHelper(name, "type " + name + " = distinct " + (isInt ? "int32" : "float64") + ";\n" +
			"function ds" + s + "(i: int32): " + name + " { return " + ctor + "; }\n" +
			"function dsRank" + s + "(xs: " + name + "[], x: " + name + ", f: int32): int32 {\n" +
			"\tlet n: int32 = 0;\n" +
			"\tfor (const v of xs) { if (v < x) { n += 1; } }\n" +
			"\tif (f == 0) { if (xs.includes(x)) { return n + 10; } return n; }\n" +
			"\tif (f == 1) { return n + (xs.indexOf(x) as int32) * 100; }\n" +
			"\tif (f == 2) { if (x == xs[0]) { return n + 1; } if (x != xs[xs.length - 1]) { return n + 2; } return n + 3; }\n" +
			"\tif (f == 3) { if (x >= xs[0]) { return n + 4; } if (x > xs[0]) { return n + 5; } if (x <= xs[0]) { return n + 6; } return n + 7; }\n" +
			tail + "}\n");
		const et: ETy = { id: id, shape: EShape.Distinct, name: name, ann: name, n: variant, lits: [] };
		this.eTypes.push(et);
		return et;
	}

	discKit(id: int32, variant: int32): ETy {
		let name = "Dk0";
		let lits: string[] = ["ifDk0", "mxDk0", "elDk0"];
		let text = "";
		if (variant == 0) {
			text = "type Dk0 =\n\t| { kind: \"c\", r: int32 }\n\t| { kind: \"s\", a: int32, b: int32 }\n\t| { kind: \"t\", x: int32 };\n" +
				"function mkDk0(k: int32, n: int32): Dk0 {\n\tconst m = n % 1000;\n\tconst r = k % 3;\n" +
				"\tif (r == 0) { return { kind: \"c\", r: m }; }\n" +
				"\tif (r == 1 || r == -1) { return { kind: \"s\", a: m, b: m + 1 }; }\n" +
				"\treturn { kind: \"t\", x: m * 2 };\n}\n" +
				"function ifDk0(d: Dk0): int32 {\n\tif (d.kind === \"c\") { return d.r; }\n\tif (d.kind === \"s\") { return d.a + d.b; }\n\treturn d.x;\n}\n" +
				"function mxDk0(d: Dk0): int32 {\n\treturn match (d.kind) {\n\t\t\"c\" => d.r,\n\t\t\"s\" => d.a * 10 + d.b,\n\t\t\"t\" => d.x - 1,\n\t};\n}\n" +
				"function elDk0(d: Dk0): int32 {\n\tif (d.kind === \"c\") { return 1; }\n\telse if (d.kind === \"s\") { return d.a; }\n\telse { return d.x; }\n}\n" +
				"function nvDk0(d: Dk0): int32 {\n\tif (d.kind === \"c\") { return d.r; }\n\tif (d.kind === \"s\") { return d.a; }\n\tif (d.kind === \"t\") { return d.x; }\n\tconst x: never = d;\n\treturn 0;\n}\n";
		} else if (variant == 1) {
			name = "Dm0";
			lits = ["ifDm0", "mxDm0"];
			text = "enum Kd0 { Num, Str, Bin }\n" +
				"type Dm0 = match (kind: Kd0) {\n\tKd0.Num => { value: int32 },\n\tKd0.Str => { text: float64 },\n\tKd0.Bin => { l: int32, r: int32 },\n};\n" +
				"function mkDm0(k: int32, n: int32): Dm0 {\n\tconst m = n % 1000;\n\tconst r = k % 3;\n" +
				"\tif (r == 0) { return { kind: Kd0.Num, value: m }; }\n" +
				"\tif (r == 1 || r == -1) { return { kind: Kd0.Str, text: m as float64 * 0.5 }; }\n" +
				"\treturn { kind: Kd0.Bin, l: m, r: m + 1 };\n}\n" +
				"function ifDm0(d: Dm0): int32 {\n\tif (d.kind === Kd0.Num) { return d.value; }\n\tif (d.kind === Kd0.Str) { return (d.text * 2.0) as int32; }\n\treturn d.l + d.r;\n}\n" +
				"function mxDm0(d: Dm0): int32 {\n\treturn match (d.kind) {\n\t\tKd0.Num => d.value,\n\t\tKd0.Str => (d.text * 4.0) as int32,\n\t\tKd0.Bin => d.l * 100 + d.r,\n\t};\n}\n";
		} else {
			name = "Db0";
			lits = ["ifDb0"];
			text = "type Db0 = match (ok: boolean) {\n\ttrue => { value: float64 },\n\tfalse => { err: int32 },\n};\n" +
				"function mkDb0(k: int32, n: int32): Db0 {\n\tconst m = n % 1000;\n" +
				"\tif (k % 2 == 0) { return { ok: true, value: m as float64 }; }\n" +
				"\treturn { ok: false, err: m };\n}\n" +
				"function ifDb0(d: Db0): int32 {\n\tif (d.ok) { return d.value as int32; }\n\treturn d.err;\n}\n";
		}
		this.useHelper(name, text);
		const et: ETy = { id: id, shape: EShape.Disc, name: name, ann: name, n: variant, lits: lits };
		this.eTypes.push(et);
		return et;
	}

	unknownKit(id: int32): ETy {
		this.useHelper("Cx", "class Cx0 { v: int32; constructor(v: int32) { this.v = v; } }\n" +
			"class Cx1 { w: float64; constructor(w: float64) { this.w = w; } }\n" +
			"class Cx2 extends Cx0 { z: int32 = 5; constructor(v: int32) { super(v); } }\n" +
			"function mkCx(k: int32, n: int32): unknown {\n\tconst m = n % 1000;\n\tconst r = k % 3;\n" +
			"\tif (r == 0) { return new Cx0(m); }\n" +
			"\tif (r == 1 || r == -1) { return new Cx1(m as float64 + 0.5); }\n" +
			"\treturn new Cx2(m);\n}\n" +
			"function scoreCx(u: unknown): int32 {\n\tif (u instanceof Cx2) { return u.v + u.z; }\n\tif (u instanceof Cx0) { return u.v; }\n\tif (u instanceof Cx1) { return (u.w * 2.0) as int32; }\n\treturn -1;\n}\n" +
			"function kindCx(u: unknown): int32 {\n\treturn u instanceof Cx1 ? 1 : u instanceof Cx0 ? 2 : 0;\n}\n" +
			"function castCx(u: unknown): int32 {\n\tif (u instanceof Cx1) { const c = u as Cx1; return (c.w as int32) + 100; }\n\treturn 0;\n}\n");
		const et: ETy = { id: id, shape: EShape.Unknown, name: "Cx", ann: "unknown", n: 0, lits: ["scoreCx", "kindCx", "castCx"] };
		this.eTypes.push(et);
		return et;
	}

	neverHelpers(): void {
		this.useHelper("failN", "function failN(code: int32): never { throw new Error(\"fail\" + String(code)); }\n" +
			"function evenN(i: int32): int32 { return i - i % 2; }\n" +
			"function pickN(i: int32): int32 | null {\n\tif (i % 2 == 0) { return i; }\n\treturn null;\n}\n" +
			"function pickF(i: int32): float64 | null {\n\tif (i % 2 == 0) { return i as float64 * 0.5; }\n\treturn null;\n}\n" +
			"function mustN(x: int32 | null): int32 {\n\tif (x === null) { failN(1); }\n\treturn x;\n}\n" +
			"function mustF(x: float64 | null, k: int32): int32 {\n\tif (x === null) { return failN(k); }\n\treturn (x * 2.0) as int32;\n}\n" +
			"function mustE(x: int32 | string): int32 {\n\tif (typeof x === \"string\") { failN(3); }\n\treturn x;\n}\n");
	}

	aliasKit(t: Ty): string {
		const X = tyTitle(t);
		const T = tyName(t);
		this.ixHelper();
		if (this.hasHelper("Als" + X)) { return X; }
		this.useHelper("Als" + X, "type Als" + X + " = " + T + ";\n" +
			"type Alc" + X + " = Als" + X + ";\n" +
			"type Ala" + X + " = Alc" + X + "[];\n" +
			"type Alf" + X + " = (x: Alc" + X + ") => Als" + X + ";\n" +
			"type Alp" + X + " = { a: Alc" + X + ", b: Als" + X + " };\n" +
			"type Alb" + X + "<V> = { v: V };\n" +
			"function alsId" + X + "(x: Alc" + X + "): Als" + X + " { return x; }\n" +
			"function alsAt" + X + "(xs: Ala" + X + ", i: int32, d: Alc" + X + "): Als" + X + " {\n" +
			"\tif (xs.length == 0) { return d; }\n" +
			"\treturn xs[ixI(i, xs.length)];\n}\n" +
			"function alsApp" + X + "(f: Alf" + X + ", x: Als" + X + "): Alc" + X + " { return f(x); }\n" +
			"function alsPair" + X + "(p: Alp" + X + ", q: { a: " + T + ", b: " + T + " }): Als" + X + " {\n" +
			"\tif (p.a == q.a) { return p.b; }\n" +
			"\treturn q.b;\n}\n" +
			"function alsBox" + X + "(b: Alb" + X + "<Als" + X + ">, c: Alb" + X + "<" + T + ">): Alc" + X + " {\n" +
			"\tif (b.v == c.v) { return b.v; }\n" +
			"\treturn c.v;\n}\n");
		return X;
	}

	selHelper(et: ETy, t: Ty): string {
		const name = "sel" + et.name + tyTitle(t);
		if (this.hasHelper(name)) { return name; }
		const T = tyName(t);
		const E = et.name;
		return this.useHelper(name, "function " + name + "(e: " + E + ", f: " + E + ", form: int32, x: " + T + ", y: " + T + "): " + T + " {\n" +
			"\tif (form == 0) { if (e == f) { return x; } return y; }\n" +
			"\tif (form == 1) { if (e != f) { return x; } return y; }\n" +
			"\tif (form == 2) { if (e === f) { return x; } return y; }\n" +
			"\tif ((e as int32) < (f as int32)) { return x; }\n" +
			"\treturn y;\n}\n");
	}

	matchHelper(et: ETy, t: Ty): string {
		const name = "m" + et.name + tyTitle(t);
		if (this.hasHelper(name)) { return name; }
		const T = tyName(t);
		const n = et.n;
		const c1 = this.rng.between(1, n - 1);
		const c2 = this.rng.between(c1, n - 1);
		let arms = "\t\t" + this.members(et, 0, c1) + " => a,\n";
		if (c2 > c1) {
			if (this.rng.chance(40)) { arms += "\t\t" + this.members(et, c1, c2) + " when a < c => c,\n"; }
			arms += "\t\t" + this.members(et, c1, c2) + " => b,\n";
		}
		if (this.rng.chance(30)) {
			arms += "\t\t" + this.members(et, c2, n) + " => c,\n";
		} else {
			arms += "\t\t_ => c,\n";
		}
		return this.useHelper(name, "function " + name + "(e: " + et.name + ", a: " + T + ", b: " + T + ", c: " + T + "): " + T + " {\n" +
			"\treturn match (e) {\n" + arms + "\t};\n}\n");
	}

	eValue(et: ETy, depth: int32): string {
		const vars = this.enumVars(et);
		if (vars.length > 0 && this.rng.chance(40)) { return this.pickEnt(vars).name; }
		if (et.shape == EShape.Bitset) { return this.maskExpr(et, 0); }
		if (et.shape == EShape.Numeric && this.rng.chance(40)) { return this.member(et); }
		if (et.shape == EShape.Literal && this.rng.chance(30)) { return quoted(et.lits[this.rng.below(et.n)]); }
		const s = this.smallInt(depth);
		if (et.shape == EShape.Numeric || et.shape == EShape.Literal) { return "at" + et.name + "(" + s + ")"; }
		if (et.shape == EShape.Distinct) { return "ds" + et.name.slice(2, et.name.length) + "(" + s + ")"; }
		return "mk" + et.name + "(" + s + ", " + this.smallInt(depth) + ")";
	}

	maskExpr(et: ETy, depth: int32): string {
		const vars = this.enumVars(et);
		if (vars.length > 0 && this.rng.chance(40)) { return this.pickEnt(vars).name; }
		let s = "(0 as " + et.ann + ")";
		const m = this.rng.between(0, 3);
		for (let j = 0; j < m; j++) { s += ".incl(" + this.member(et) + ")"; }
		if (depth < 2 && this.rng.chance(30)) { return "(" + s + " " + this.pickOp(BIT_OPS) + " " + this.maskExpr(et, depth + 1) + ")"; }
		return s;
	}

	maskUpdate(et: ETy, v: string, indent: string): string {
		const k = this.rng.below(5);
		if (k == 0) { return indent + v + " |= " + this.member(et) + ";\n"; }
		if (k == 1) { return indent + v + " &= " + this.maskExpr(et, 0) + ";\n"; }
		if (k == 2) { return indent + v + " ^= " + this.maskExpr(et, 0) + ";\n"; }
		if (k == 3) { return indent + v + " = " + v + ".excl(" + this.member(et) + ");\n"; }
		return indent + v + " = " + v + ".incl(" + this.member(et) + ").union(" + this.maskExpr(et, 0) + ");\n";
	}

	shapeType(shape: EShape): ETy {
		if (shape == EShape.Bitset) { return this.enumType(EShape.Bitset); }
		if (shape == EShape.Literal) { return this.enumType(EShape.Literal); }
		if (shape == EShape.Distinct) { return this.enumKit(EShape.Distinct, this.rng.below(2)); }
		if (shape == EShape.Disc) { return this.enumKit(EShape.Disc, this.rng.below(3)); }
		if (shape == EShape.Unknown) { return this.enumKit(EShape.Unknown, 0); }
		return this.enumType(EShape.Numeric);
	}

	enumExpr(t: Ty, depth: int32): string {
		const shape = E_SHAPES[this.pickW(W.EnumNumeric, W.EnumNever)];
		if (shape == EShape.Alias) { return this.aliasExpr(t, depth); }
		if (shape == EShape.Never) { return this.neverExpr(t, depth); }
		if (!this.reserve(6 as int64)) { return ""; }
		const et = this.shapeType(shape);
		if (shape == EShape.Numeric) {
			const a = this.eValue(et, depth + 1);
			if (this.rng.chance(50)) { return this.lift("(" + a + " as int32)", t); }
			const sel = this.selHelper(et, t);
			const b = this.eValue(et, depth + 1);
			return sel + "(" + a + ", " + b + ", " + String(this.rng.below(4)) + ", " + this.expr(t, depth + 1) + ", " + this.expr(t, depth + 1) + ")";
		}
		if (shape == EShape.Match) {
			const m = this.matchHelper(et, t);
			const e = this.eValue(et, depth + 1);
			return m + "(" + e + ", " + this.expr(t, depth + 1) + ", " + this.expr(t, depth + 1) + ", " + this.expr(t, depth + 1) + ")";
		}
		if (shape == EShape.Bitset) {
			if (!this.reserve(et.n as int64)) { return ""; }
			const a = this.maskExpr(et, 0);
			const b = this.maskExpr(et, 0);
			return this.lift("bs" + et.name + "(" + a + ", " + b + ", " + String(this.rng.below(9)) + ")", t);
		}
		if (shape == EShape.Distinct) {
			const s = et.name.slice(2, et.name.length);
			const m = this.rng.between(1, 3);
			let xs = "";
			for (let j = 0; j < m; j++) { xs += (j == 0 ? "" : ", ") + this.eValue(et, depth + 1); }
			const x = this.eValue(et, depth + 1);
			return this.lift("dsRank" + s + "([" + xs + "], " + x + ", " + String(this.rng.below(5)) + ")", t);
		}
		if (shape == EShape.Literal) {
			const d = this.eValue(et, depth + 1);
			const k = this.rng.below(4);
			if (k == 3) { return this.lift("cmp" + et.name + "(" + d + ", " + this.eValue(et, depth + 1) + ", " + String(this.rng.below(4)) + ")", t); }
			const f = k == 0 ? "if" : k == 1 ? "mw" : "mx";
			return this.lift(f + et.name + "(" + d + ", " + String(this.rng.between(-9, 9)) + ", " + String(this.rng.between(-9, 9)) + ")", t);
		}
		return this.lift(et.lits[this.rng.below(et.lits.length)] + "(" + this.eValue(et, depth + 1) + ")", t);
	}

	aliasExpr(t: Ty, depth: int32): string {
		if (!this.reserve(6 as int64)) { return ""; }
		const X = this.aliasKit(t);
		const k = this.rng.below(5);
		if (k == 0) { return "alsId" + X + "(" + this.expr(t, depth + 1) + ")"; }
		if (k == 1) {
			const xs = "[" + this.expr(t, depth + 1) + ", " + this.expr(t, depth + 1) + "]";
			return "alsAt" + X + "(" + xs + ", " + this.smallInt(depth) + ", " + this.expr(t, depth + 1) + ")";
		}
		if (k == 2) {
			const f = this.lambda([t], t, depth, this.spare(1 as int64));
			if (!this.reserve(f.cost)) { return ""; }
			return "alsApp" + X + "(" + f.text + ", " + this.expr(t, depth + 1) + ")";
		}
		if (k == 3) {
			const p = "{ a: " + this.expr(t, depth + 1) + ", b: " + this.expr(t, depth + 1) + " }";
			return "alsPair" + X + "(" + p + ", { a: " + this.expr(t, depth + 1) + ", b: " + this.expr(t, depth + 1) + " })";
		}
		return "alsBox" + X + "({ v: " + this.expr(t, depth + 1) + " }, { v: " + this.expr(t, depth + 1) + " })";
	}

	neverExpr(t: Ty, depth: int32): string {
		if (!this.reserve(6 as int64)) { return ""; }
		this.neverHelpers();
		const k = this.rng.below(4);
		const s = this.smallInt(depth + 1);
		if (k == 0) { return this.lift("mustN(pickN(evenN(" + s + ")))", t); }
		if (k == 1) { return this.lift("mustE(" + s + ")", t); }
		if (k == 2) { return this.lift("mustF(pickF(evenN(" + s + ")), " + String(this.rng.below(9)) + ")", t); }
		const et = this.enumKit(EShape.Disc, 0);
		return this.lift("nvDk0(" + this.eValue(et, depth + 1) + ")", t);
	}

	enumStatement(t: Ty, indent: string, depth: int32): string {
		const shape = E_SHAPES[this.pickW(W.EnumNumeric, W.EnumNever)];
		if (shape == EShape.Alias) {
			const X = this.aliasKit(t);
			const value = this.expr(t, 0);
			return indent + "let " + this.newLocal(t) + ": Alc" + X + " = " + value + ";\n";
		}
		if (shape == EShape.Never) {
			const value = this.neverExpr(t, 0);
			if (value == "") { return ""; }
			return indent + "let " + this.newLocal(t) + ": " + tyName(t) + " = " + value + ";\n";
		}
		const et = this.shapeType(shape);
		const vars = this.enumVars(et);
		if (vars.length > 0 && this.rng.chance(60)) {
			const v = this.pickEnt(vars).name;
			if (et.shape == EShape.Bitset) { return this.maskUpdate(et, v, indent); }
			if (et.shape == EShape.Literal && this.rng.chance(50)) { return indent + v + " = next" + et.name + "(" + v + ");\n"; }
			return indent + v + " = " + this.eValue(et, 0) + ";\n";
		}
		const value = this.eValue(et, 0);
		const name = this.entName("z");
		this.ents.push({ kind: EntKind.EnumVar, name: name, ty: Ty.Int32, params: [], len: et.id, cost: 0 as int64 });
		return indent + "let " + name + ": " + et.ann + " = " + value + ";\n";
	}

	excHazard(pct: int32): boolean {
		if (this.excHaz < 0) { this.excHaz = this.rng.chance(30) ? 1 : 0; }
		return this.excHaz == 1 && this.rng.chance(pct);
	}

	excNext(): int32 {
		const n = this.excCount;
		this.excCount = this.excCount + 1;
		return n;
	}

	excBase(): void {
		this.useHelper("ixI", "function ixI(i: int32, n: int32): int32 { const r = i % n; return r < 0 ? r + n : r; }\n");
		this.useHelper("excBase", EXC_BASE);
	}

	excThrower(j: int32): string {
		this.excBase();
		if (j == 0) {
			return this.useHelper("excT0", "function excT0(k: int32, tr: string[]): int32 {\n" +
				"\tconst m = ixI(k, 997);\n" +
				"\ttr.push(\"t0\");\n" +
				"\tif (m % 3 == 0) { throw new Error(\"a\" + String(m)); }\n" +
				"\treturn m;\n}\n");
		}
		if (j == 1) {
			return this.useHelper("excT1", "function excT1(k: int32, tr: string[]): int32 {\n" +
				"\tconst m = ixI(k, 997);\n" +
				"\ttr.push(\"t1\");\n" +
				"\tif (m % 4 == 1) { throw new ExcErr2(\"b\" + String(m), m, \"T\"); }\n" +
				"\treturn m + 1;\n}\n");
		}
		this.excThrower(0);
		this.excThrower(1);
		return this.useHelper("excT2", "function excT2(k: int32, tr: string[]): int32 {\n" +
			"\tconst m = ixI(k, 997);\n" +
			"\ttr.push(\"t2\");\n" +
			"\tconst a = excT0(m + 1, tr);\n" +
			"\tif (m % 5 == 2) { throw new ExcErr(\"c\" + String(a), a); }\n" +
			"\treturn a + excT1(m, tr);\n}\n");
	}

	excFill(depth: int32, ind: string): string {
		if (depth >= this.depthMax || !this.rng.chance(50)) { return ""; }
		return this.block(depth + 1, ind, false, Ty.Int32, false);
	}

	excTrips(): int32 { return this.rng.between(1, this.tripMax < 4 ? this.tripMax : 4); }

	excLoopVar(): string {
		const name = "i" + String(this.loopCount);
		this.loopCount = this.loopCount + 1;
		return name;
	}

	excArms(tr: string, x: string, ind: string): string {
		return ind + "if (" + x + " instanceof ExcErr2) { " + tr + ".push(\"c2:\" + " + x + ".tag + String(" + x + ".code) + " + x + ".message); }\n" +
			ind + "else if (" + x + " instanceof ExcErr) { " + tr + ".push(\"c1:\" + String(" + x + ".code) + " + x + ".message); }\n" +
			ind + "else { " + tr + ".push(\"c0:\" + " + x + ".message); }\n";
	}

	excPush(tr: string, th: string, arg: string): string {
		return tr + ".push(\"t\" + String(" + th + "(" + arg + ", " + tr + ")));\n";
	}

	excStatement(t: Ty, indent: string, depth: int32): string {
		const k = this.pickW(W.ExcCatch, W.ExcNarrow);
		if (k == 0) { return this.excCatch(indent, depth); }
		if (k == 1) { return this.excFinally(indent, depth); }
		if (k == 2) { return this.excRethrow(indent, depth); }
		if (k == 3) { return this.excUnwind(indent); }
		if (k == 4) { return this.excDefer(indent, depth); }
		if (k == 5) { return this.excDeferLoop(indent, depth); }
		if (k == 6) { return this.excRecover(indent, depth); }
		if (k == 7) { return this.excResultStmt(t, indent); }
		return this.excNarrowStmt(t, indent);
	}

	excCatch(indent: string, depth: int32): string {
		if (!this.reserve(12 as int64)) { return ""; }
		const i1 = indent + "\t";
		const th = this.excThrower(this.rng.below(3));
		const tr = this.entName("v");
		const x = this.entName("d");
		let body = this.excFill(depth, i1);
		body += i1 + this.excPush(tr, th, this.smallInt(0));
		body += this.excFill(depth, i1);
		body += i1 + tr + ".push(\"ok\");\n";
		return indent + "const " + tr + ": string[] = [];\n" +
			indent + "try {\n" + body + indent + "} catch (" + x + ") {\n" +
			this.excArms(tr, x, i1) +
			indent + "}\n" +
			indent + "excFold(" + tr + ");\n";
	}

	excFinally(indent: string, depth: int32): string {
		const trips = this.excTrips();
		if (!this.reserve((18 + 8 * trips) as int64)) { return ""; }
		const i1 = indent + "\t";
		const i2 = i1 + "\t";
		const th = this.excThrower(this.rng.below(3));
		const tr = this.entName("v");
		const x = this.entName("d");
		const head = indent + "const " + tr + ": string[] = [];\n";
		const tail = indent + "excFold(" + tr + ");\n";
		const hazard = this.excHazard(40);
		const form = hazard ? 1 + this.rng.below(2) : (this.rng.chance(35) ? 3 : 0);
		if (form == 3) {
			const name = "excF" + String(this.excNext());
			this.useHelper(name, "function " + name + "(k: int32, tr: string[]): int32 {\n" +
				"\tconst m = ixI(k, 997);\n" +
				"\ttry {\n" +
				"\t\tif (m % 4 == 1) { return m; }\n" +
				"\t\ttr.push(\"t\" + String(" + th + "(m, tr)));\n" +
				"\t} catch (x) {\n" +
				"\t\ttr.push(\"c:\" + x.message);\n" +
				"\t} finally {\n" +
				"\t\ttr.push(\"F\");\n" +
				"\t}\n" +
				"\treturn 0 - m;\n}\n");
			return head + indent + tr + ".push(\"r\" + String(" + name + "(" + this.smallInt(0) + ", " + tr + ")));\n" + tail;
		}
		if (form == 1) {
			this.directive(EXC_SKIP_FINALLY);
			const kv = this.entName("n");
			const iv = this.excLoopVar();
			const jump = this.rng.chance(50) ? "continue" : "break";
			return head +
				indent + "const " + kv + ": int32 = ixI(" + this.smallInt(0) + ", 997);\n" +
				indent + "for (let " + iv + ": int32 = 0; " + iv + " < " + String(trips) + "; " + iv + "++) {\n" +
				i1 + "try {\n" +
				i2 + "if (ixI(" + kv + " + " + iv + ", 4) == 1) { " + jump + "; }\n" +
				i2 + this.excPush(tr, th, kv + " + " + iv) +
				i1 + "} catch (" + x + ") {\n" +
				this.excArms(tr, x, i2) +
				i1 + "} finally {\n" +
				i2 + tr + ".push(\"F\");\n" +
				i1 + "}\n" +
				i1 + tr + ".push(\".\");\n" +
				indent + "}\n" + tail;
		}
		if (form == 2) {
			this.directive(EXC_SKIP_FINALLY);
			return head +
				indent + "try {\n" +
				i1 + "try {\n" +
				i2 + this.excPush(tr, th, this.smallInt(0)) +
				i1 + "} finally {\n" +
				i2 + tr + ".push(\"F\");\n" +
				i2 + "if (ixI(" + this.smallInt(0) + ", 2) == 0) { throw new ExcErr(\"fin\", 1); }\n" +
				i1 + "}\n" +
				i1 + tr + ".push(\"after\");\n" +
				indent + "} catch (" + x + ") {\n" +
				this.excArms(tr, x, i1) +
				indent + "}\n" + tail;
		}
		return head +
			indent + "try {\n" +
			i1 + tr + ".push(\"a\");\n" +
			i1 + "try {\n" +
			this.excFill(depth, i2) +
			i2 + this.excPush(tr, th, this.smallInt(0)) +
			i1 + "} finally {\n" +
			i2 + tr + ".push(\"F1\");\n" +
			i1 + "}\n" +
			i1 + tr + ".push(\"b\");\n" +
			indent + "} catch (" + x + ") {\n" +
			this.excArms(tr, x, i1) +
			indent + "} finally {\n" +
			i1 + tr + ".push(\"F2\");\n" +
			indent + "}\n" + tail;
	}

	excRethrow(indent: string, depth: int32): string {
		if (!this.reserve(20 as int64)) { return ""; }
		const i1 = indent + "\t";
		const i2 = i1 + "\t";
		const th = this.excThrower(this.rng.below(3));
		const tr = this.entName("v");
		const xa = this.entName("d");
		const xb = this.entName("d");
		const hazard = this.excHazard(40);
		const form = hazard ? 3 : this.rng.below(3);
		const inner = this.excFill(depth, i2) + i2 + this.excPush(tr, th, this.smallInt(0));
		let handler = i2 + tr + ".push(\"c:\" + " + xa + ".message);\n";
		const cond = "ixI(" + this.smallInt(0) + ", 2) == 0";
		if (form == 0 || form == 3) { handler += i2 + "if (" + cond + ") { throw " + xa + "; }\n"; }
		if (form == 1) { handler += i2 + "if (" + cond + ") { throw new ExcErr2(\"w\" + " + xa + ".message, 7, \"W\"); }\n"; }
		if (form == 2) { handler = i2 + "if (" + xa + " instanceof ExcErr2) { throw " + xa + "; }\n" + handler; }
		let fin = i1 + "} catch (" + xa + ") {\n" + handler + i1 + "}\n";
		if (form == 3) {
			this.directive(EXC_SKIP_FINALLY);
			fin = i1 + "} catch (" + xa + ") {\n" + handler + i1 + "} finally {\n" + i2 + tr + ".push(\"F1\");\n" + i1 + "}\n";
		}
		const outerFin = this.rng.chance(30) ? " finally {\n" + i1 + tr + ".push(\"F2\");\n" + indent + "}" : "";
		return indent + "const " + tr + ": string[] = [];\n" +
			indent + "try {\n" +
			i1 + "try {\n" + inner + fin +
			i1 + tr + ".push(\"after\");\n" +
			indent + "} catch (" + xb + ") {\n" +
			this.excArms(tr, xb, i1) +
			indent + "}" + outerFin + "\n" +
			indent + "excFold(" + tr + ");\n";
	}

	excUnwind(indent: string): string {
		if (!this.reserve(40 as int64)) { return ""; }
		const th = this.excThrower(0);
		const name = "excU" + String(this.excNext());
		const own: string[] = [
			"\tconst s = \"u\" + String(m);\n",
			"\tconst xs: string[] = [\"x\" + String(m), \"y\"];\n",
			"\tconst b: ExcBag = { s: \"b\" + String(m), xs: [\"p\", String(m)], n: m };\n",
			"\tconst o = new ExcObj(\"o\" + String(m), m);\n",
			"\tconst ys: int32[] = [m, m + 1];\n",
			"\tconst q: ExcFault = { code: m, why: \"q\" + String(m) };\n",
		];
		const reads: string[] = ["s.length", "xs.length", "b.n + b.xs.length", "o.xs.length + o.name.length", "ys.length", "q.why.length"];
		let decl = "";
		let sum = "0";
		let live = 0;
		for (let i = 0; i < own.length; i++) {
			if (live < 2 || this.rng.chance(55)) {
				decl += own[i];
				sum += " + " + reads[i];
				live++;
			}
		}
		const modulus = this.rng.between(4, 7);
		this.useHelper(name, "function " + name + "(k: int32, d: int32, tr: string[]): int32 {\n" +
			"\tconst m = ixI(k, 997);\n" +
			decl +
			"\ttr.push(\"e\" + String(d));\n" +
			"\tif (ixI(m + d, " + String(modulus) + ") == 0) { throw new ExcErr2(\"u\" + String(d), m, \"U\"); }\n" +
			"\tif (d <= 0) { return " + sum + "; }\n" +
			"\tconst r = " + name + "(m, d - 1, tr);\n" +
			"\ttr.push(\"x\" + String(d));\n" +
			"\treturn r + " + sum + ";\n}\n");
		const i1 = indent + "\t";
		const tr = this.entName("v");
		const x = this.entName("d");
		return indent + "const " + tr + ": string[] = [];\n" +
			indent + "try {\n" +
			i1 + tr + ".push(\"r\" + String(" + name + "(" + this.smallInt(0) + ", " + String(this.rng.between(1, 4)) + ", " + tr + ")));\n" +
			indent + "} catch (" + x + ") {\n" +
			this.excArms(tr, x, i1) +
			indent + "}\n" +
			indent + "excFold(" + tr + ");\n";
	}

	excDefer(indent: string, depth: int32): string {
		if (!this.reserve(16 as int64)) { return ""; }
		const i1 = indent + "\t";
		const i2 = i1 + "\t";
		const th = this.excThrower(this.rng.below(3));
		const tr = this.entName("v");
		const head = indent + "const " + tr + ": string[] = [];\n";
		const tail = indent + "excFold(" + tr + ");\n";
		const form = this.rng.below(4);
		if (form == 1) {
			const x = this.entName("d");
			return head +
				indent + "try {\n" +
				i1 + "defer " + tr + ".push(\"in\");\n" +
				i1 + this.excPush(tr, th, this.smallInt(0)) +
				i1 + tr + ".push(\"ok\");\n" +
				indent + "} catch (" + x + ") {\n" +
				this.excArms(tr, x, i1) +
				indent + "}\n" + tail;
		}
		if (form == 2) {
			const x = this.entName("d");
			const name = "excD" + String(this.excNext());
			this.useHelper(name, "function " + name + "(k: int32, tr: string[]): int32 {\n" +
				"\tdefer tr.push(\"d0\");\n" +
				"\tconst v = " + th + "(k, tr);\n" +
				"\tdefer tr.push(\"d1\");\n" +
				"\treturn v;\n}\n");
			return head +
				indent + "try {\n" +
				i1 + tr + ".push(\"r\" + String(" + name + "(" + this.smallInt(0) + ", " + tr + ")));\n" +
				indent + "} catch (" + x + ") {\n" +
				this.excArms(tr, x, i1) +
				indent + "}\n" + tail;
		}
		if (form == 3) {
			const c = this.entName("n");
			return head +
				indent + "let " + c + ": int32 = ixI(" + this.smallInt(0) + ", 99);\n" +
				indent + "{\n" +
				i1 + "defer " + tr + ".push(\"c\" + String(" + c + "));\n" +
				i1 + c + " = " + c + " + 7;\n" +
				i1 + tr + ".push(\"b\" + String(" + c + "));\n" +
				this.excFill(depth, i1) +
				indent + "}\n" + tail;
		}
		return head +
			indent + "{\n" +
			i1 + "defer " + tr + ".push(\"d0\");\n" +
			i1 + tr + ".push(\"b0\");\n" +
			i1 + "{\n" +
			i2 + "defer " + tr + ".push(\"d1\");\n" +
			i2 + tr + ".push(\"b1\");\n" +
			this.excFill(depth, i2) +
			i1 + "}\n" +
			i1 + tr + ".push(\"b2\");\n" +
			indent + "}\n" + tail;
	}

	excLoopBody(depth: int32, ind: string, trips: int32): string {
		const savedMult = this.mult;
		this.mult = this.mult * (trips as int64);
		const text = this.excFill(depth, ind);
		this.mult = savedMult;
		return text;
	}

	excDeferLoop(indent: string, depth: int32): string {
		const trips = this.excTrips();
		if (!this.reserve((16 + 8 * trips) as int64)) { return ""; }
		const i1 = indent + "\t";
		const i2 = i1 + "\t";
		const th = this.excThrower(this.rng.below(3));
		const tr = this.entName("v");
		const head = indent + "const " + tr + ": string[] = [];\n";
		const tail = indent + "excFold(" + tr + ");\n";
		const hazard = this.excHazard(50);
		const form = hazard ? 1 + this.rng.below(2) * 2 : (this.rng.chance(50) ? 0 : (this.rng.chance(50) ? 2 : 4));
		if (form == 2) {
			const name = "excL" + String(this.excNext());
			this.useHelper(name, "function " + name + "(n: int32, tr: string[]): int32 {\n" +
				"\tdefer tr.push(\"d0\");\n" +
				"\tfor (let i: int32 = 0; i < 4; i++) {\n" +
				"\t\tdefer tr.push(\"l\" + String(i));\n" +
				"\t\tif (i == n) { return i * 10; }\n" +
				"\t\ttr.push(\"b\" + String(i));\n" +
				"\t}\n" +
				"\tdefer tr.push(\"late\");\n" +
				"\treturn -1;\n}\n");
			return head + indent + tr + ".push(\"r\" + String(" + name + "(ixI(" + this.smallInt(0) + ", 6), " + tr + ")));\n" + tail;
		}
		const iv = this.excLoopVar();
		const kv = this.entName("n");
		const set = indent + "const " + kv + ": int32 = ixI(" + this.smallInt(0) + ", 997);\n";
		const open = indent + "for (let " + iv + ": int32 = 0; " + iv + " < " + String(trips) + "; " + iv + "++) {\n";
		if (form == 1) {
			this.directive(EXC_SKIP_DEFER);
			const jump = this.rng.chance(50) ? "continue" : "break";
			return head + set + open +
				i1 + "defer " + tr + ".push(\"d\" + String(" + iv + "));\n" +
				i1 + "if (ixI(" + kv + ", " + String(trips + 1) + ") == " + iv + ") { " + jump + "; }\n" +
				i1 + tr + ".push(\"b\" + String(" + iv + "));\n" +
				indent + "}\n" + tail;
		}
		if (form == 3) {
			this.directive(EXC_SKIP_DEFER);
			const w = this.entName("n");
			return head + set +
				indent + "let " + w + ": int32 = 0;\n" +
				indent + "while (" + w + " < " + String(trips) + ") {\n" +
				i1 + w + "++;\n" +
				i1 + "defer " + tr + ".push(\"w\" + String(" + w + "));\n" +
				i1 + "if (ixI(" + kv + ", " + String(trips + 1) + ") == " + w + ") { continue; }\n" +
				i1 + tr + ".push(\"b\" + String(" + w + "));\n" +
				indent + "}\n" + tail;
		}
		if (form == 4) {
			const x = this.entName("d");
			return head + set +
				indent + "try {\n" +
				i1 + "for (let " + iv + ": int32 = 0; " + iv + " < " + String(trips) + "; " + iv + "++) {\n" +
				i2 + "defer " + tr + ".push(\"d\" + String(" + iv + "));\n" +
				i2 + this.excPush(tr, th, kv + " + " + iv) +
				i1 + "}\n" +
				indent + "} catch (" + x + ") {\n" +
				this.excArms(tr, x, i1) +
				indent + "}\n" + tail;
		}
		this.scope.push({ name: iv, ty: Ty.Int32, writable: false });
		const fill = this.excLoopBody(depth, i1, trips);
		this.scope.pop();
		return head + set + open +
			i1 + "defer " + tr + ".push(\"d\" + String(" + iv + "));\n" +
			i1 + tr + ".push(\"b\" + String(" + iv + "));\n" +
			fill +
			indent + "}\n" + tail;
	}

	excRecover(indent: string, depth: int32): string {
		const trips = this.excTrips();
		if (!this.reserve((14 + 8 * trips) as int64)) { return ""; }
		const i1 = indent + "\t";
		const i2 = i1 + "\t";
		const i3 = i2 + "\t";
		const th = this.excThrower(this.rng.below(3));
		const tr = this.entName("v");
		const x = this.entName("d");
		const kv = this.entName("n");
		const iv = this.excLoopVar();
		const hazard = this.excHazard(40);
		const form = hazard ? 4 : this.rng.below(4);
		const set = indent + "const " + kv + ": int32 = ixI(" + this.smallInt(0) + ", 997);\n";
		const head = indent + "const " + tr + ": string[] = [];\n" + set;
		const tail = indent + "excFold(" + tr + ");\n";
		const open = indent + "for (let " + iv + ": int32 = 0; " + iv + " < " + String(trips) + "; " + iv + "++) {\n";
		if (form == 3) {
			return head +
				indent + "try {\n" +
				i1 + "for (let " + iv + ": int32 = 0; " + iv + " < " + String(trips) + "; " + iv + "++) {\n" +
				i2 + this.excPush(tr, th, kv + " + " + iv) +
				i2 + tr + ".push(\".\");\n" +
				i1 + "}\n" +
				indent + "} catch (" + x + ") {\n" +
				this.excArms(tr, x, i1) +
				indent + "}\n" + tail;
		}
		this.scope.push({ name: iv, ty: Ty.Int32, writable: false });
		const fill = this.excLoopBody(depth, i2, trips);
		this.scope.pop();
		let handler = i2 + tr + ".push(\"r\" + " + x + ".message);\n";
		if (form == 1 || form == 4) { handler += i2 + "continue;\n"; }
		if (form == 2) { handler += i2 + "break;\n"; }
		let fin = "";
		if (form == 4) {
			this.directive(EXC_SKIP_FINALLY);
			fin = " finally {\n" + i2 + tr + ".push(\"F\");\n" + i1 + "}";
		} else if (form == 0 && this.rng.chance(40)) {
			fin = " finally {\n" + i2 + tr + ".push(\"F\");\n" + i1 + "}";
		}
		return head + open +
			i1 + "try {\n" +
			fill +
			i2 + this.excPush(tr, th, kv + " + " + iv) +
			i1 + "} catch (" + x + ") {\n" +
			handler +
			i1 + "}" + fin + "\n" +
			i1 + tr + ".push(\".\");\n" +
			indent + "}\n" + tail;
	}

	excResult(okKind: int32, t: Ty, errKind: int32): string {
		this.excBase();
		const A = okKind == 0 ? tyTitle(t) : okKind == 1 ? "Obj" : okKind == 2 ? "Bag" : "Void";
		const B = errKind == 0 ? "S" : errKind == 1 ? "E" : "F";
		const name = "excRs" + A + B;
		if (this.hasHelper(name + "1")) { return name; }
		const OK = okKind == 0 ? tyName(t) : okKind == 1 ? "ExcObj" : okKind == 2 ? "ExcBag" : "void";
		const ER = errKind == 0 ? "string" : errKind == 1 ? "ExcFail" : "ExcFault";
		const params = okKind == 0 ? "k: int32, v: " + tyName(t) : "k: int32";
		const okVal = okKind == 0 ? "v" : okKind == 1 ? "new ExcObj(\"o\" + String(m), m)" : okKind == 2 ? "{ s: \"b\" + String(m), xs: [\"x\", String(m)], n: m }" : "null";
		const e1 = errKind == 0 ? "\"e\" + String(m)" : errKind == 1 ? "ExcFail.Odd" : "{ code: m, why: \"f\" + String(m) }";
		const e2 = errKind == 0 ? "\"m\" + String(m)" : errKind == 1 ? "ExcFail.Neg" : "{ code: m + 1, why: \"g\" + String(m) }";
		const sig = "Result<" + OK + ", " + ER + ">";
		this.useHelper(name + "0", "function " + name + "0(" + params + "): " + sig + " {\n" +
			"\tconst m = ixI(k, 997);\n" +
			"\tif (m % 5 == 3) { return Result.err(" + e1 + "); }\n" +
			"\treturn Result.ok(" + okVal + ");\n}\n");
		let chain = "\tconst m = ixI(k, 997);\n";
		if (okKind == 0) {
			chain += "\tconst a = try " + name + "0(k, v);\n" +
				"\tif (m % 7 == 2) { return Result.err(" + e2 + "); }\n" +
				"\tconst b = try " + name + "0(m + 1, a);\n" +
				"\treturn Result.ok(b);\n";
		} else if (okKind == 3) {
			chain += "\ttry " + name + "0(k);\n" +
				"\tif (m % 7 == 2) { return Result.err(" + e2 + "); }\n" +
				"\ttry " + name + "0(m + 1);\n" +
				"\treturn Result.ok(null);\n";
		} else {
			chain += "\tconst a = try " + name + "0(k);\n" +
				"\tif (m % 7 == 2 || a.xs.length > 5) { return Result.err(" + e2 + "); }\n" +
				"\tconst b = try " + name + "0(m + 1);\n" +
				"\treturn Result.ok(b);\n";
		}
		this.useHelper(name + "1", "function " + name + "1(" + params + "): " + sig + " {\n" + chain + "}\n");
		return name;
	}

	excResultStmt(t: Ty, indent: string): string {
		if (!this.reserve(14 as int64)) { return ""; }
		const okKind = this.rng.below(4);
		const errKind = this.rng.below(3);
		const name = this.excResult(okKind, t, errKind);
		const tr = this.entName("v");
		const r = this.entName("n");
		const k = this.smallInt(0);
		const args = okKind == 0 ? k + ", " + this.expr(t, 0) : k;
		const okText = okKind == 0 ? "String(" + r + ".value)" : okKind == 1 ? r + ".value.name + String(" + r + ".value.xs.length)" : okKind == 2 ? r + ".value.s + String(" + r + ".value.n)" : "\"\"";
		const errText = errKind == 0 ? r + ".error" : errKind == 1 ? "excErrText(" + r + ".error)" : "String(" + r + ".error.code) + " + r + ".error.why";
		let text = indent + "const " + tr + ": string[] = [];\n" +
			indent + "const " + r + " = " + name + "1(" + args + ");\n" +
			indent + "if (" + r + ".ok) { " + tr + ".push(\"ok\" + " + okText + "); } else { " + tr + ".push(\"err:\" + " + errText + "); }\n";
		if (okKind == 0 && this.rng.chance(50)) {
			text += indent + tr + ".push(\"c\" + String(try " + name + "1(" + this.smallInt(0) + ", " + this.expr(t, 0) + ") catch " + this.expr(t, 0) + "));\n";
		}
		return text + indent + "excFold(" + tr + ");\n";
	}

	excNarrowFn(t: Ty): string {
		const T = tyName(t);
		const X = tyTitle(t);
		this.excBase();
		this.useHelper("excNul" + X, "function excNul" + X + "(k: int32, v: " + T + "): " + T + " | null {\n" +
			"\tif (ixI(k, 3) == 0) { return null; }\n" +
			"\treturn v;\n}\n");
		this.useHelper("excOr" + X, "function excOr" + X + "(x: " + T + " | null, d: " + T + "): " + T + " {\n" +
			"\tif (x === null) { return d; }\n" +
			"\treturn x;\n}\n");
		this.useHelper("excBox" + X, "function excBox" + X + "(k: int32, v: " + T + "): " + T + " | string | null {\n" +
			"\tconst r = ixI(k, 3);\n" +
			"\tif (r == 0) { return null; }\n" +
			"\tif (r == 1) { return \"s\" + String(v); }\n" +
			"\treturn v;\n}\n");
		const name = "excDo" + X;
		if (this.hasHelper(name)) { return name; }
		const nul = "excNul" + X;
		let body = "";
		let live = 0;
		if (this.rng.chance(60)) {
			body += "\tif (n !== null) { acc = n; tr += \"A\" + String(n); } else { tr += \"N\"; }\n";
			live++;
		}
		if (this.rng.chance(60)) {
			body += "\tn = " + nul + "(m + 1, v);\n" +
				"\tif (n === null) { tr += \"n\"; } else { acc = n; tr += \"B\" + String(acc); }\n";
			live++;
		}
		if (this.rng.chance(40)) {
			body += "\tn = null;\n" +
				"\tif (n != null) { tr += \"never\"; }\n";
			live++;
		}
		if (this.rng.chance(60) || live == 0) {
			body += "\tfor (let i: int32 = 0; i < 4; i++) {\n" +
				"\t\tif (n === null) { n = " + nul + "(m + i, v); tr += \"l\"; }\n" +
				"\t\telse { acc = n; n = null; tr += \"m\" + String(acc); }\n" +
				"\t}\n";
		}
		if (this.rng.chance(60)) {
			body += "\tconst u = excBox" + X + "(m, v);\n" +
				"\tif (u === null) { tr += \"u0\"; }\n" +
				"\telse if (typeof u === \"string\") { tr += \"us\" + u; }\n" +
				"\telse { acc = u; tr += \"un\" + String(u); }\n";
		}
		if (this.rng.chance(50)) {
			body += "\tif (n === null) { return tr + \"R\"; }\n" +
				"\tacc = n;\n" +
				"\ttr += \"z\";\n";
		}
		this.useHelper(name, "function " + name + "(k: int32, v: " + T + "): string {\n" +
			"\tconst m = ixI(k, 997);\n" +
			"\tlet tr = \"\";\n" +
			"\tlet acc: " + T + " = v;\n" +
			"\tlet n: " + T + " | null = " + nul + "(m, v);\n" +
			body +
			"\treturn tr + \" \" + String(excOr" + X + "(" + nul + "(m, v), acc)) + String(acc);\n}\n");
		return name;
	}

	excNodeHelpers(): void {
		this.excBase();
		this.useHelper("excNode", "class ExcNode {\n" +
			"\tv: int32;\n" +
			"\tnext: ExcNode | null;\n" +
			"\tconstructor(v: int32, next: ExcNode | null) {\n" +
			"\t\tthis.v = v;\n" +
			"\t\tthis.next = next;\n" +
			"\t}\n}\n" +
			"function excList(n: int32): ExcNode | null {\n" +
			"\tlet head: ExcNode | null = null;\n" +
			"\tfor (let i: int32 = n; i > 0; i--) { head = new ExcNode(i * 10, head); }\n" +
			"\treturn head;\n}\n" +
			"function excSum(h: ExcNode | null): int32 {\n" +
			"\tlet cur = h;\n" +
			"\tlet s: int32 = 0;\n" +
			"\twhile (cur != null) { s += cur.v; cur = cur.next; }\n" +
			"\treturn s;\n}\n" +
			"function excLast(h: ExcNode | null): int32 {\n" +
			"\tlet cur = h;\n" +
			"\tlet last: int32 = -1;\n" +
			"\twhile (cur != null) { last = cur.v; if (cur.next == null) { break; } cur = cur.next; }\n" +
			"\treturn last;\n}\n");
	}

	excNarrowStmt(t: Ty, indent: string): string {
		if (!this.reserve(14 as int64)) { return ""; }
		const k = this.rng.below(5);
		this.excBase();
		if (k == 3) {
			this.excNodeHelpers();
			return indent + "excMix(String(excSum(excList(ixI(" + this.smallInt(0) + ", 6)))) + \":\" + String(excLast(excList(ixI(" + this.smallInt(0) + ", 6)))));\n";
		}
		if (k == 4) {
			this.useHelper("excMk", "function excMk(k: int32): ExcObj | null {\n" +
				"\tif (ixI(k, 3) == 0) { return null; }\n" +
				"\treturn new ExcObj(\"o\" + String(k), k);\n}\n");
			const o = this.entName("n");
			return indent + "const " + o + ": ExcObj | null = excMk(" + this.smallInt(0) + ");\n" +
				indent + "if (" + o + " !== null) { excMix(" + o + ".name + String(" + o + ".xs.length)); } else { excMix(\"null\"); }\n";
		}
		const name = this.excNarrowFn(t);
		return indent + "excMix(" + name + "(" + this.smallInt(0) + ", " + this.expr(t, 0) + "));\n";
	}

	excWrapHelper(t: Ty): string {
		const T = tyName(t);
		const X = tyTitle(t);
		this.excBase();
		const thr = "excWt" + X;
		this.useHelper(thr, "function " + thr + "(k: int32, v: " + T + "): " + T + " {\n" +
			"\tif (ixI(k, 3) == 1) { throw new ExcErr(\"w\" + String(k), k); }\n" +
			"\treturn v;\n}\n");
		const name = "excW" + X;
		if (this.hasHelper(name)) { return name; }
		const form = this.rng.below(3);
		let body = "\ttry { return " + thr + "(k, v); } catch (x) { return d; }\n";
		if (form == 1) { body = "\ttry { return " + thr + "(k, v); } catch (x) { if (x instanceof ExcErr) { return d; } return v; }\n"; }
		if (form == 2) { body = "\ttry {\n\t\ttry { return " + thr + "(k, v); } finally { excLog = (excLog + 1) % 1000003; }\n\t} catch (x) { return d; }\n"; }
		this.useHelper(name, "function " + name + "(k: int32, v: " + T + ", d: " + T + "): " + T + " {\n" + body + "}\n");
		return name;
	}

	excExpr(t: Ty, depth: int32): string {
		const k = this.pickW(W.ExcWrap, W.ExcNullable);
		if (k == 0) {
			if (!this.reserve(10 as int64)) { return ""; }
			const name = this.excWrapHelper(t);
			return name + "(" + this.smallInt(depth) + ", " + this.expr(t, depth + 1) + ", " + this.expr(t, depth + 1) + ")";
		}
		if (k == 1) {
			if (!this.reserve(14 as int64)) { return ""; }
			const name = this.excResult(0, t, this.rng.below(3));
			if (this.matchArms > 0) {
				const wrap = "excOe" + name.slice(5);
				this.useHelper(wrap, "function " + wrap + "(k: int32, v: " + tyName(t) + ", d: " + tyName(t) + "): " + tyName(t) + " {\n" +
					"\treturn try " + name + "1(k, v) catch d;\n}\n");
				return wrap + "(" + this.smallInt(depth) + ", " + this.expr(t, depth + 1) + ", " + this.expr(t, depth + 1) + ")";
			}
			return "(try " + name + "1(" + this.smallInt(depth) + ", " + this.expr(t, depth + 1) + ") catch " + this.expr(t, depth + 1) + ")";
		}
		if (!this.reserve(6 as int64)) { return ""; }
		this.excNarrowFn(t);
		const X = tyTitle(t);
		return "excOr" + X + "(excNul" + X + "(" + this.smallInt(depth) + ", " + this.expr(t, depth + 1) + "), " + this.expr(t, depth + 1) + ")";
	}

	routineDecl(t: Ty, indent: string): string {
		const outer: Var[] = [];
		for (const v of this.scope) {
			if (v.ty == t) { outer.push(v); }
		}
		const name = this.entName("r");
		const n = this.entName("q");
		this.scope.push({ name: n, ty: Ty.Int32, writable: false });
		const body = this.routine(t, 1, FN_COST_CAP);
		this.scope.pop();
		const cost = body.cost + (ROUTINE_FRAMES as int64);
		this.ents.push({ kind: EntKind.Callable, name: name, ty: t, params: [Ty.Int32], len: 0, cost: cost });
		const head = this.rng.chance(50) && !this.atTop ? "function " + name + "(" + n + ": int32): " + tyName(t) + " {\n" : "const " + name + " = (" + n + ": int32): " + tyName(t) + " => {\n";
		let text = indent + head +
			indent + "\tif (" + n + " <= 0 || " + n + " >= " + String(ROUTINE_FRAMES) + ") { return " + body.text + "; }\n" +
			(outer.length == 0 ? "" : indent + "\tif (" + n + " == 2) { return " + outer[this.rng.below(outer.length)].name + "; }\n") +
			indent + "\treturn " + name + "(" + n + " - 1);\n" +
			indent + (head.startsWith("const ") ? "};\n" : "}\n");
		if (this.rng.chance(50)) {
			const alias = this.entName("k");
			this.ents.push({ kind: EntKind.Callable, name: alias, ty: t, params: [Ty.Int32], len: 0, cost: cost });
			text += indent + "const " + alias + " = " + name + ";\n";
		}
		return text;
	}

	newLocal(t: Ty): string {
		const name = "l" + String(this.localCount);
		this.localCount = this.localCount + 1;
		this.scope.push({ name: name, ty: t, writable: true });
		return name;
	}

	matchLet(indent: string): string {
		const ints = this.intTys();
		if (ints.length == 0) { return ""; }
		const s = ints[this.rng.below(ints.length)];
		const t = this.pickTy();
		const scrutinee = this.expr(s, 1);
		const used: int32[] = [];
		let arms = "";
		const armCount = this.rng.between(1, 3);
		for (let a = 0; a < armCount; a++) {
			let pattern = "";
			const alternatives = this.rng.between(1, 2);
			for (let k = 0; k < alternatives; k++) {
				const v = isSigned(s) ? this.rng.between(-8, 8) : this.rng.below(17);
				let seen = false;
				for (const u of used) { if (u == v) { seen = true; } }
				if (seen) { continue; }
				used.push(v);
				pattern = pattern == "" ? String(v) : pattern + " | " + String(v);
			}
			if (pattern == "") { continue; }
			this.matchArms++;
			arms += indent + "\t" + pattern + " => " + this.expr(t, 1) + ",\n";
			this.matchArms--;
		}
		this.matchArms++;
		arms += indent + "\t_ => " + this.expr(t, 1) + ",\n";
		this.matchArms--;
		const name = this.newLocal(t);
		return indent + "let " + name + ": " + tyName(t) + " = match (" + scrutinee + ") {\n" + arms + indent + "};\n";
	}

	statement(depth: int32, indent: string, inLoop: boolean, ret: Ty, inFn: boolean): string {
		this.nodesLeft--;
		if (!this.reserve(1 as int64)) { return ""; }
		if (this.fams.length > 0 && this.rng.chance(this.wt(W.StmtFam))) {
			const fam = this.famStatement(indent, depth);
			if (fam != "") { return fam; }
		}
		const nested = depth < this.depthMax;
		let total = 0;
		for (let i = W.StmtLet as int32; i <= (W.StmtReturn as int32); i++) { total += this.w[i]; }
		const k = this.rng.below(total);
		const cLet = this.wt(W.StmtLet);
		const cAssign = cLet + this.wt(W.StmtAssign);
		const cCompound = cAssign + this.wt(W.StmtCompound);
		const cIf = cCompound + this.wt(W.StmtIf);
		const cFor = cIf + this.wt(W.StmtFor);
		const cMatch = cFor + this.wt(W.StmtMatch);
		const cBreak = cMatch + this.wt(W.StmtBreak);
		if (k < cLet) {
			const t = this.pickTy();
			const value = this.expr(t, 0);
			return indent + "let " + this.newLocal(t) + ": " + tyName(t) + " = " + value + ";\n";
		}
		if (k < cAssign && this.wt(W.StmtAssign) > 0) {
			const t = this.pickTy();
			const vars = this.visible(t, true);
			if (vars.length > 0) {
				const v = vars[this.rng.below(vars.length)];
				return indent + v.name + " = " + this.expr(t, 0) + ";\n";
			}
		}
		if (k < cCompound && this.wt(W.StmtCompound) > 0) {
			const t = this.pickTy();
			const vars = this.visible(t, true);
			if (vars.length > 0 && !trapsOnOverflow(t)) {
				const v = vars[this.rng.below(vars.length)];
				const op = ["+=", "-=", "*="][this.rng.below(3)];
				return indent + v.name + " " + op + " " + this.expr(t, 0) + ";\n";
			}
		}
		if (k < cIf && nested && this.wt(W.StmtIf) > 0) {
			let text = indent + "if " + this.cond(0) + " {\n" + this.block(depth + 1, indent + "\t", inLoop, ret, inFn) + indent + "}";
			if (this.rng.chance(this.wt(W.StmtElse))) { text += " else {\n" + this.block(depth + 1, indent + "\t", inLoop, ret, inFn) + indent + "}"; }
			return text + "\n";
		}
		const available = (this.costCap - this.cost) / this.mult;
		const maxTrips = Math.min(this.tripMax, (available / (3 as int64)) as int32);
		if (k < cFor && nested && maxTrips > 0) {
			const name = "i" + String(this.loopCount);
			this.loopCount = this.loopCount + 1;
			const trips = this.rng.between(1, maxTrips);
			if (!this.reserve((2 * trips) as int64)) { return ""; }
			const savedMult = this.mult;
			this.mult = this.mult * (trips as int64);
			this.scope.push({ name: name, ty: Ty.Int32, writable: false });
			const body = this.block(depth + 1, indent + "\t", true, ret, inFn);
			this.scope.pop();
			this.mult = savedMult;
			return indent + "for (let " + name + ": int32 = 0; " + name + " < " + String(trips) + "; " + name + "++) {\n" +
				body + indent + "}\n";
		}
		if (k < cMatch && this.wt(W.StmtMatch) > 0) {
			const m = this.matchLet(indent);
			if (m != "") { return m; }
		}
		if (k < cBreak && inLoop && this.wt(W.StmtBreak) > 0) {
			return indent + "if " + this.cond(0) + " { " + (this.rng.chance(50) ? "break" : "continue") + "; }\n";
		}
		if (inFn && this.wt(W.StmtReturn) > 0 && this.rng.chance(50)) {
			return indent + "if " + this.cond(0) + " { return " + this.expr(ret, 0) + "; }\n";
		}
		const t = this.pickTy();
		const value = this.expr(t, 0);
		return indent + "let " + this.newLocal(t) + ": " + tyName(t) + " = " + value + ";\n";
	}

	block(depth: int32, indent: string, inLoop: boolean, ret: Ty, inFn: boolean): string {
		const saved = this.scope.length;
		const savedEnts = this.ents.length;
		const n = this.rng.between(1, this.stmtMax);
		const savedBlock = this.blockId;
		this.blockCount++;
		this.blockId = this.blockCount;
		let out = "";
		for (let i = 0; i < n; i++) {
			if (this.nodesLeft == 0 || this.cost + this.mult > this.costCap) { break; }
			out += this.statement(depth, indent, inLoop, ret, inFn);
		}
		while (this.scope.length > saved) { this.scope.pop(); }
		while (this.ents.length > savedEnts) { this.ents.pop(); }
		this.blockId = savedBlock;
		return out;
	}

	fn(index: int32): string {
		const ret = this.pickTy();
		const params: Ty[] = [];
		const paramCount = this.rng.below(4);
		let sig = "";
		this.scope = [];
		this.ents = [];
		this.entCount = 0;
		this.localCount = 0;
		this.loopCount = 0;
		this.cost = 0 as int64;
		this.costCap = FN_COST_CAP;
		this.mult = 1 as int64;
		for (let p = 0; p < paramCount; p++) {
			const t = this.pickTy();
			params.push(t);
			const name = "p" + String(p);
			this.scope.push({ name: name, ty: t, writable: false });
			sig = sig == "" ? name + ": " + tyName(t) : sig + ", " + name + ": " + tyName(t);
		}
		const body = this.block(0, "\t", false, ret, true);
		this.ents = [];
		const tail = "\treturn " + this.expr(ret, 0) + ";\n";
		const name = "f" + String(index);
		this.fns.push({ name: name, ret: ret, params: params, cost: this.cost });
		return "function " + name + "(" + sig + "): " + tyName(ret) + " {\n" + body + tail + "}\n";
	}
}

function plantDecls(plant: Plant): string {
	if (plant == Plant.None) { return ""; }
	if (plant == Plant.Model) { return "function modelDelta(): int32 { return 1; }\n"; }
	if (plant == Plant.San) {
		return "@include(\"stdlib.h\")\n" +
			"extern function malloc(size: uint64): Ptr<void>;\n" +
			"extern function free(p: Ptr<void>): void;\n" +
			"function plantDelta(): int32 {\n" +
			"\tconst raw = malloc(8 as uint64);\n" +
			"\tfree(raw);\n" +
			"\tconst p = raw as Ptr<uint8>;\n" +
			"\tp[0] = 1 as uint8;\n" +
			"\treturn 0;\n" +
			"}\n";
	}
	const flag = plant == Plant.Backend ? "js" : "debug";
	const inside = plant == Plant.Backend ? "1" : "0";
	const outside = plant == Plant.Backend ? "0" : "1";
	return "when (" + flag + ") {\n" +
		"\tfunction plantDelta(): int32 { return " + inside + "; }\n" +
		"} else {\n" +
		"\tfunction plantDelta(): int32 { return " + outside + "; }\n" +
		"}\n";
}

export function generate(seed: uint64, f: Features): string {
	const g = new Gen();
	g.rng = Rng.seeded(seed);
	for (const t of ALL_TYS) { if (f.types.has(t)) { g.tys.push(t); } }
	for (const m of ALL_FAMS) {
		if (!f.fams.has(m)) { continue; }
		if (!isTaskFam(m)) {
			g.fams.push(m);
		} else if (f.w[(W.FamClosure as int32) + (m as int32)] > 0) {
			g.taskFams.push(m);
		}
	}
	g.stmtMax = f.stmts;
	g.depthMax = f.depth;
	g.exprMax = f.exprDepth;
	g.tripMax = f.trips;
	g.w = f.w;

	let globals = "";
	for (let i = 0; i < f.globals; i++) {
		const t = g.pickTy();
		const name = "g" + String(i);
		globals += "let " + name + ": " + tyName(t) + " = " + g.literal(t) + ";\n";
		g.globals.push({ name: name, ty: t, writable: true });
	}

	let fns = "";
	for (let i = 0; i < f.funcs; i++) { fns += g.fn(i) + "\n"; }

	let top = "";
	for (let b = 0; b < f.top; b++) {
		g.scope = [];
		g.ents = [];
		g.cost = 0 as int64;
		g.costCap = FN_COST_CAP;
		g.mult = 1 as int64;
		g.atTop = true;
		top += g.block(0, "", false, Ty.Int32, false);
		g.atTop = false;
	}

	g.scope = [];
	g.ents = [];
	g.cost = 0 as int64;
	g.costCap = TOP_COST_CAP;
	g.mult = 1 as int64;
	let entries = "";
	for (let e = 0; e < f.entries; e++) {
		const target = g.fns[g.rng.below(g.fns.length)];
		const value = g.call(target.ret, 0);
		if (value == "") { continue; }
		entries += "console.log(\"e" + String(e) + " \" + String(" + value + "));\n";
	}

	const forced = f.plant == Plant.Model && g.taskFams.length == 0;
	g.taskPlant = f.plant == Plant.Model;
	if (g.taskFams.length > 0 || forced) {
		g.rng = Rng.seeded(seed ^ TASK_SALT);
		g.taskScenarios(forced);
	}

	let plantSite = "";
	if (f.plant != Plant.None && f.plant != Plant.Model) {
		for (const v of g.globals) {
			if (plantSite == "" && !isFloat(v.ty)) {
				plantSite = v.name + " = " + v.name + " ^ (plantDelta() as " + tyName(v.ty) + ");\n";
			}
		}
		if (plantSite == "") { plantSite = "console.log(\"plant \" + String(plantDelta()));\n"; }
	}

	let prints = "";
	for (const v of g.globals) { prints += "console.log(\"" + v.name + " \" + String(" + v.name + "));\n"; }
	prints += g.clsPrints();

	if (g.hasHelper("excBase")) { prints += "console.log(\"excLog \" + String(excLog));\n"; }
	let head = "// smith seed=" + String(seed) + " features=" + f.format() + "\n";
	for (const d of g.directives) { head += d + "\n"; }
	for (const line of g.imports) { head += line + "\n"; }
	return head + g.helperText + plantDecls(f.plant) + globals + "\n" + fns + g.taskText + top + entries + g.taskCalls + plantSite + prints;
}

test "the same seed and features give the same program" {
	const f = Features.defaults();
	assert generate(11 as uint64, f) == generate(11 as uint64, f);
}

test "different seeds give different programs" {
	const f = Features.defaults();
	assert generate(11 as uint64, f) != generate(12 as uint64, f);
}

test "numeric loop and routine weights stay capped and restore their scope" {
	for (let seed = 1; seed < 13; seed++) {
		const g = new Gen();
		g.rng = Rng.seeded(seed as uint64);
		g.tys = [Ty.Int8, Ty.Int64, Ty.Float64];
		g.stmtMax = 32;
		g.depthMax = 8;
		g.exprMax = 8;
		g.tripMax = 64;
		g.fams = seed % 2 == 0 ? [Fam.Closure, Fam.Union, Fam.Generic] : [];
		g.fn(0);
		assert g.cost <= FN_COST_CAP;
		assert g.fns[0].cost <= FN_COST_CAP;
		assert g.mult == (1 as int64);
		assert g.scope.length == g.fns[0].params.length;
		assert g.ents.length == 0;
	}
}

test "a call is refused before its weighted product could overflow" {
	const g = new Gen();
	g.rng = Rng.seeded(1 as uint64);
	g.mult = FN_COST_CAP;
	g.costCap = FN_COST_CAP;
	g.fns = [{
		name: "huge",
		ret: Ty.Int8,
		params: [],
		cost: 9223372036854775806 as int64,
	}];
	assert g.call(Ty.Int8, 0) == "";
	assert g.cost == (0 as int64);
}

test "call overhead is charged for every loop iteration" {
	const g = new Gen();
	g.rng = Rng.seeded(1 as uint64);
	g.mult = 64 as int64;
	g.costCap = 63 as int64;
	g.fns = [{ name: "tiny", ret: Ty.Int8, params: [], cost: 0 as int64 }];
	assert g.call(Ty.Int8, 0) == "";
	assert g.cost == (0 as int64);
}

test "an exhausted weighted budget emits no block and preserves scope" {
	for (const t of [Ty.Int8, Ty.Float64]) {
		const g = new Gen();
		g.rng = Rng.seeded(1 as uint64);
		g.tys = [t];
		g.costCap = FN_COST_CAP;
		g.cost = FN_COST_CAP - (1 as int64);
		g.mult = 64 as int64;
		const text = g.block(0, "", false, t, true);
		assert text == "";
		assert g.cost == FN_COST_CAP - (1 as int64);
		assert g.scope.length == 0 && g.ents.length == 0;
	}
}

test "a legal deep vector cannot explode generated source" {
	const parsed = Features.defaults().overlay(
		"fams=none funcs=1 globals=1 stmts=32 depth=4 expr=1 trips=64 entries=1",
	);
	assert parsed.ok;
	if (parsed.ok) {
		assert generate(1 as uint64, parsed.value).byteLength < 1048576;
	}
}

function withWeights(text: string): Features {
	const parsed = Features.defaults().overlay(text);
	if (!parsed.ok) { unreachable; }
	return parsed.value;
}

function countOver(needle: string, seeds: int32, f: Features): int32 {
	let n = 0;
	for (let seed = 1; seed <= seeds; seed++) { n += countOf(generate(seed as uint64, f), needle); }
	return n;
}

test "a nested routine recurses at most its frame bound and may be named as a value" {
	const f = withWeights("fams=closure w.closure.routine=40");
	let routines = 0;
	let aliases = 0;
	let arrows = 0;
	for (let seed = 1; seed <= 20; seed++) {
		const text = generate(seed as uint64, f);
		for (const line of text.split("\n")) {
			const t = line.trim();
			if ((t.startsWith("function r") || (t.startsWith("const r") && t.contains(": int32): "))) && t.endsWith(" {") && line.startsWith("\t")) { routines++; }
			if (t.startsWith("const r") && t.endsWith(" => {")) { arrows++; }
			if (t.startsWith("if (q") && t.contains(" <= 0 || q") && !t.contains(" >= " + String(ROUTINE_FRAMES) + ") { return ")) { assert false; }
			if (t.startsWith("const k") && t.contains(" = r") && t.endsWith(";") && !t.contains("(")) { aliases++; }
		}
	}
	assert routines > 10;
	assert arrows > 3 && arrows < routines;
	assert aliases > 3;
	assert countOver(" == 2) { return ", 20, f) > 10;
}

test "a top-level block declares no function inside a block" {
	const f = withWeights("fams=closure w.closure.routine=40");
	let routines = 0;
	for (let seed = 1; seed <= 20; seed++) {
		const text = generate(seed as uint64, f);
		const at = text.indexOf("\nconsole.log(\"e");
		let inTop = false;
		for (const line of text.slice(0, at < 0 ? text.length : at).split("\n")) {
			if (line.startsWith("for (") || line.startsWith("if (")) { inTop = true; }
			if (line.startsWith("function ")) { inTop = false; }
			if (inTop && line.startsWith("\t") && line.trim().startsWith("function r")) { assert false; }
			if (inTop && line.trim().startsWith("const r") && line.endsWith(" => {")) { routines++; }
		}
	}
	assert routines > 0;
}

test "default weights keep the pinned stream" {
	const sizes = [23008, 14006, 27999, 14767];
	const closureSizes = [12836, 12148, 16450, 17808];
	const closure = withWeights("fams=closure top=0 w.closure.routine=0");
	for (let i = 0; i < 4; i++) {
		assert generate((i + 1) as uint64, withWeights("fams=closure,union,generic top=0 w.closure.routine=0")).replace(" top=0", "").replace(" w.closure.routine=0", "").byteLength == sizes[i];
		assert generate((i + 1) as uint64, closure).replace(" top=0", "").replace(" w.closure.routine=0", "").byteLength == closureSizes[i];
	}
}

test "the program head carries the non-default weights and nothing else" {
	const f = withWeights("w.expr.ternary=80");
	const text = generate(5 as uint64, f);
	assert text.startsWith("// smith seed=5 features=" + f.format() + "\n");
	assert text.contains(" plant=none w.expr.ternary=80\n");
}

test "a ternary-heavy vector multiplies ternaries and a zero weight removes them" {
	const base = withWeights("fams=none");
	const aimed = withWeights("fams=none w.expr.ternary=80 w.expr.leaf=10 w.expr.binary=4 w.expr.unary=2 w.expr.convert=2 w.expr.call=2");
	const none = withWeights("fams=none w.expr.ternary=0");
	assert countOver(" ? ", 12, aimed) > 5 * countOver(" ? ", 12, base);
	assert countOver(" ? ", 12, none) == 0;
}

test "a zero expression weight keeps its construct out of every expression" {
	const g = new Gen();
	g.tys = [Ty.Int32, Ty.Int8];
	g.exprMax = 5;
	g.fams = [Fam.Closure];
	g.fns = [{ name: "f0", ret: Ty.Int32, params: [], cost: 1 as int64 }];
	g.costCap = TOP_COST_CAP;
	g.w = withWeights("w.expr.ternary=0 w.expr.call=0 w.expr.unary=0 w.expr.convert=0 w.closure.iife=0").w;
	for (let seed = 1; seed <= 200; seed++) {
		g.rng = Rng.seeded(seed as uint64);
		g.nodesLeft = GEN_NODE_CAP;
		const text = g.expr(Ty.Int32, 0);
		assert !text.contains(" ? ") && !text.contains("f0(") && !text.contains("(~") && !text.contains("conv") && !text.contains("wrap") && !text.contains("safeNeg");
		assert !text.contains("(q");
	}
}

test "every signed width adds, subtracts, multiplies and negates through a guarded helper" {
	const g = new Gen();
	g.exprMax = 0;
	g.costCap = TOP_COST_CAP;
	for (const t of [Ty.Int8, Ty.Int16, Ty.Int32, Ty.Int64]) {
		g.tys = [t];
		for (let seed = 1; seed <= 100; seed++) {
			g.rng = Rng.seeded(seed as uint64);
			g.nodesLeft = GEN_NODE_CAP;
			const sum = g.binary(t, 0);
			assert sum.startsWith("safe") || (!sum.contains(" + ") && !sum.contains(" - ") && !sum.contains(" * "));
			const neg = g.unary(t, 0);
			assert neg.startsWith("safeNeg") || neg.startsWith("(~");
		}
	}
}

test "a zero binary weight leaves the fallbacks of call and convert out of binary" {
	const g = new Gen();
	g.tys = [Ty.Int32];
	g.exprMax = 5;
	g.costCap = TOP_COST_CAP;
	g.w = withWeights("w.expr.binary=0 w.expr.call=60").w;
	for (let seed = 1; seed <= 200; seed++) {
		g.rng = Rng.seeded(seed as uint64);
		g.nodesLeft = GEN_NODE_CAP;
		const text = g.expr(Ty.Int32, 0);
		assert !text.contains(" + ") && !text.contains(" * ") && !text.contains("safeAdd") && !text.contains("safeMul") && !text.contains("safeDiv");
	}
}

test "a zero statement weight keeps its statement out of every block" {
	const g = new Gen();
	g.tys = ALL_TYS;
	g.stmtMax = 6;
	g.depthMax = 4;
	g.exprMax = 3;
	g.tripMax = 4;
	g.costCap = TOP_COST_CAP;
	g.w = withWeights("w.stmt.for=0 w.stmt.match=0 w.stmt.compound=0 w.stmt.break=0").w;
	for (let seed = 1; seed <= 100; seed++) {
		g.rng = Rng.seeded(seed as uint64);
		g.nodesLeft = GEN_NODE_CAP;
		g.cost = 0 as int64;
		const text = g.block(0, "", false, Ty.Int32, true);
		assert !text.contains("for (") && !text.contains("match (") && !text.contains("+= ") && !text.contains("continue");
	}
}

test "family weights shape the choice among enabled families only" {
	const g = new Gen();
	g.tys = [Ty.Int32];
	g.exprMax = 3;
	g.costCap = TOP_COST_CAP;
	g.fams = [Fam.Closure, Fam.Union];
	g.w = withWeights("w.fam.closure=0 w.fam.generic=100").w;
	for (let seed = 1; seed <= 100; seed++) {
		g.rng = Rng.seeded(seed as uint64);
		g.nodesLeft = GEN_NODE_CAP;
		const text = g.famExpr(Ty.Int32, 0);
		assert !text.contains("BoxG") && !text.contains("(q");
	}
}

test "a weight cannot lift the cost bound of a routine" {
	const f = withWeights("w.expr.call=100 w.expr.fam=100 w.stmt.fam=100 w.stmt.let=100 w.stmt.for=100 w.stmt.if=100");
	for (let seed = 1; seed <= 12; seed++) {
		const g = new Gen();
		g.rng = Rng.seeded(seed as uint64);
		g.tys = [Ty.Int8, Ty.Int32];
		g.stmtMax = 32;
		g.depthMax = 8;
		g.exprMax = 8;
		g.tripMax = 64;
		g.fams = [Fam.Closure, Fam.Union, Fam.Generic];
		g.w = f.w;
		g.fn(0);
		g.fn(1);
		assert g.cost <= FN_COST_CAP;
		assert g.nodesLeft >= 0;
	}
}

test "the program head names its seed and full feature vector" {
	const f = Features.defaults();
	const text = generate(5 as uint64, f);
	assert text.startsWith("// smith seed=5 features=" + f.format() + "\n");
}

test "a san plant writes freed memory and leaves the printed result alone" {
	const f: Features = { ...Features.defaults(), plant: Plant.San };
	const text = generate(5 as uint64, f);
	assert text.contains("\tfree(raw);\n\tconst p = raw as Ptr<uint8>;\n\tp[0] = 1 as uint8;\n\treturn 0;\n");
	assert text.contains("plantDelta()");
	assert !text.contains("when (");
	const r = Features.defaults().overlay("plant=san");
	assert r.ok;
	if (r.ok) { assert r.value.plant == Plant.San && r.value.format().contains(" plant=san"); }
}

test "a planted program declares the plant on both sides of its flag" {
	const f: Features = { ...Features.defaults(), plant: Plant.Opt };
	const text = generate(5 as uint64, f);
	assert text.contains("when (debug) {");
	assert text.contains("plantDelta()");
}

test "fams=none emits no closure, union or generic construct" {
	const r = Features.defaults().overlay("fams=none");
	assert r.ok;
	if (r.ok) {
		for (let seed = 1; seed < 9; seed++) {
			const text = generate(seed as uint64, r.value);
			assert !text.contains("(q");
			assert !text.contains("| string | null");
			assert !text.contains("BoxG");
			assert !text.contains("PtS");
			assert !text.contains("ixI");
			assert !text.contains(": string = ");
			assert !text.contains("ownHooks");
			assert !text.contains("Vec<");
			assert !text.contains("CellQ");
		}
	}
}

test "the aggregate family alone reaches each of its shapes" {
	const f = withWeights("fams=agg types=int32,uint8 stmts=8 w.stmt.fam=80");
	const shapes = [": PtS", " = mkS", "{ ...s", ".n = s", "\tsetS", " = new CellC", ".p = ", ".put(", ".get()", "eqS", ".n.c", ".v = "];
	const seen: boolean[] = shapes.map((x: string): boolean => false);
	let alias = false;
	for (let seed = 1; seed < 41; seed++) {
		const text = generate(seed as uint64, f);
		for (let i = 0; i < shapes.length; i++) { if (text.contains(shapes[i])) { seen[i] = true; } }
		for (const line of text.split("\n")) {
			const t = line.trim();
			if (t.startsWith("const k") && t.contains(" = k") && t.endsWith(";") && t.length < 16) { alias = true; }
		}
	}
	for (let i = 0; i < shapes.length; i++) { assert seen[i]; }
	assert alias;
}

test "struct equality is never drawn for a float field" {
	const f = withWeights("fams=agg types=float64 w.agg.eq=100");
	for (let seed = 1; seed < 21; seed++) {
		assert countOf(generate(seed as uint64, f), "eqSFloat64(") <= 1;
	}
}

test "the aggregate weights choose between struct and class statements" {
	const structs = withWeights("fams=agg types=int32 w.agg.class=0 w.agg.alias=0 w.agg.poke=0");
	const cells = withWeights("fams=agg types=int32 w.agg.struct=0 w.agg.copy=0 w.agg.write=0 w.agg.ref=0");
	let s = 0;
	let k = 0;
	for (let seed = 1; seed < 21; seed++) {
		const a = generate(seed as uint64, structs);
		const b = generate(seed as uint64, cells);
		assert !a.contains("const k");
		assert !b.contains("let s");
		s += countOf(a, "let s");
		k += countOf(b, "const k");
	}
	assert s > 20 && k > 20;
}

test "the collection family alone reaches each of its shapes" {
	const f = withWeights("fams=coll types=int32,uint8 stmts=8 w.stmt.fam=80");
	const shapes = ["[ixI(", ".pop(); }", ".splice(ixI(", ".setLength(", ".fill(", ".reverse();", " = pushA", "[...a", ", ...a",
		".concat(", ").map(", "for (const x", "for (let j", "for (const [x", "let [l", ", ...r", "new Map<int32, ", "new Set<",
		" ?? ", ".delete(", ".add(", ".has(", ".includes(", ".indexOf(", ".join(\",\").length", "] = w"];
	const seen: boolean[] = shapes.map((x: string): boolean => false);
	for (let seed = 1; seed < 41; seed++) {
		const text = generate(seed as uint64, f);
		for (let i = 0; i < shapes.length; i++) { if (text.contains(shapes[i])) { seen[i] = true; } }
	}
	for (let i = 0; i < shapes.length; i++) { assert seen[i]; }
}

test "a family ternary is never narrowed by a raw cast" {
	const g = new Gen();
	g.rng = Rng.seeded(3 as uint64);
	g.tys = [Ty.Int32, Ty.Uint8];
	g.fams = [Fam.Coll];
	g.exprMax = 3;
	g.w = withWeights("w.expr.fam=100 w.coll.index=100").w;
	g.ents = [{ kind: EntKind.ArrayVar, name: "a0", ty: Ty.Int32, params: [], len: 0, cost: 0 as int64 }];
	let wrapped = 0;
	for (let i = 0; i < 200; i++) {
		g.costCap = TOP_COST_CAP;
		g.cost = 0 as int64;
		g.nodesLeft = GEN_NODE_CAP;
		const text = g.convert(Ty.Uint8, 0);
		assert !text.startsWith("((a0.length > 0 ? ");
		if (text.startsWith("wrapInt32ToUint8((a0.length > 0 ? ")) { wrapped++; }
	}
	assert wrapped > 10;
}

test "no ternary sits under arithmetic inside an else arm" {
	const g = new Gen();
	g.rng = Rng.seeded(5 as uint64);
	g.tys = [Ty.Int32, Ty.Uint8];
	g.fams = [Fam.Coll, Fam.Str, Fam.Own];
	g.exprMax = 4;
	g.w = withWeights("w.expr.ternary=60 w.expr.fam=60").w;
	g.ents = [
		{ kind: EntKind.ArrayVar, name: "a0", ty: Ty.Int32, params: [], len: 0, cost: 0 as int64 },
		{ kind: EntKind.HeldVar, name: "h1", ty: Ty.Int32, params: [], len: 0, cost: 0 as int64 },
	];
	let outside = 0;
	for (let i = 0; i < 300; i++) {
		g.costCap = TOP_COST_CAP;
		g.cost = 0 as int64;
		g.nodesLeft = GEN_NODE_CAP;
		g.elseArms = 1;
		assert !g.binary(Ty.Int32, 0).contains(" ? ");
		g.elseArms = 0;
		if (g.binary(Ty.Int32, 0).contains(" ? ")) { outside++; }
	}
	assert outside > 30;
}

test "a float element is never searched or kept in a Set" {
	const f = withWeights("fams=coll types=int32,float64 stmts=8 w.stmt.fam=80 w.coll.keyed=20 w.coll.size=20");
	let searched = 0;
	let floatDecls = 0;
	for (let seed = 1; seed < 21; seed++) {
		const text = generate(seed as uint64, f);
		assert !text.contains("new Set<float64>");
		const floats: string[] = [];
		for (const line of text.split("\n")) {
			if (line.startsWith("function ") || line.startsWith("}")) { floats.setLength(0); }
			const t = line.trim();
			const name = t.slice(t.indexOf(" ") + 1, t.indexOf(t.startsWith("let a") ? ":" : " ="));
			const source = t.slice(t.indexOf("= ") + 2, t.length - 1);
			if (t.startsWith("let a") && t.contains(": float64[] =")) {
				floats.push(name);
				floatDecls++;
			}
			if (t.startsWith("const a") && (t.contains("pushAFloat64(") || floats.includes(source))) { floats.push(name); }
			for (const a of floats) { assert !t.contains(a + ".includes(") && !t.contains(a + ".indexOf("); }
			if (t.contains(".includes(") || t.contains(".indexOf(")) { searched++; }
		}
	}
	assert searched > 10 && floatDecls > 10;
}

test "every for-of over a collection carries its trip bound" {
	const f = withWeights("fams=coll types=int32,uint8 stmts=8 w.stmt.fam=80 w.coll.loop=20");
	let loops = 0;
	for (let seed = 1; seed < 21; seed++) {
		const text = generate(seed as uint64, f);
		const forOf = countOf(text, "for (const x") + countOf(text, "for (const [x");
		assert forOf == countOf(text, "\tif (j");
		loops += forOf;
	}
	assert loops > 20;
}

test "the string family alone reaches each of its shapes" {
	const f = withWeights("fams=str types=int32,uint8 stmts=8 w.stmt.fam=80");
	const shapes = [".slice(", ".substring(", ".charAt(", "atS(", ".toUpperCase()", ".toLowerCase()", ".trim()", ".trimStart()",
		".trimEnd()", ".repeat(", ".padStart(", ".padEnd(", ".replace(", ".replaceAll(", ".split(", "String(", "${", ").length",
		".indexOf(\"", ".lastIndexOf(\"", "codeS(", " == ", " != ", " < ", " > ", ".includes(", ".startsWith(", ".endsWith(",
		" += (", "let s", " as string)", "\\n", "\\\"", "中"];
	const seen: boolean[] = shapes.map((x: string): boolean => false);
	for (let seed = 1; seed < 41; seed++) {
		const text = generate(seed as uint64, f);
		for (let i = 0; i < shapes.length; i++) { if (text.contains(shapes[i])) { seen[i] = true; } }
	}
	for (let i = 0; i < shapes.length; i++) { assert seen[i]; }
}

test "a string variable grows only by a bounded slice" {
	const f = withWeights("fams=str types=int32 stmts=8 w.stmt.fam=80 w.str.append=10 w.str.assign=10");
	let writes = 0;
	for (let seed = 1; seed < 21; seed++) {
		for (const line of generate(seed as uint64, f).split("\n")) {
			const t = line.trim();
			if (!t.startsWith("s")) { continue; }
			if (t.contains(" += (")) {
				assert t.endsWith(").slice(0, 8);");
				writes++;
			} else if (t.contains(" = (") && t.indexOf(" = (") < 6) {
				assert t.endsWith(").slice(0, 32);");
				writes++;
			}
		}
	}
	assert writes > 20;
}

test "the ownership family alone reaches each of its shapes" {
	const f = withWeights("fams=own types=int32,uint8 stmts=8 w.stmt.fam=80");
	const shapes = ["onDestroy(this o: OwnInt32)", "onCopy(this ref d: OwnUint8", ": OwnInt32 = mkO", ": OwnUint8 = o", " = move o", "= takeOInt32(move o",
		".push(move o", "\tbumpO", "(out o", ": OwnInt32[] = [o", ".push(o", ".tag.length", "].v : ", ".v"];
	const seen: boolean[] = shapes.map((x: string): boolean => false);
	let reassign = false;
	for (let seed = 1; seed < 41; seed++) {
		const text = generate(seed as uint64, f);
		for (let i = 0; i < shapes.length; i++) { if (text.contains(shapes[i])) { seen[i] = true; } }
		for (const line of text.split("\n")) {
			const t = line.trim();
			if (t.startsWith("o") && t.contains(" = o") && t.length < 16) { reassign = true; }
		}
	}
	for (let i = 0; i < shapes.length; i++) { assert seen[i]; }
	assert reassign;
}

function ownNameAt(text: string, at: int32): string {
	let end = at + 1;
	while (end < text.length && text.charCodeAt(end) >= 48 && text.charCodeAt(end) <= 57) { end++; }
	return end > at + 1 ? text.slice(at, end) : "";
}

function indentOf(line: string): int32 { return line.length - line.trimStart().length; }

test "a moved variable was declared in the moving block and is never named again" {
	const f = withWeights("fams=own types=int32,uint8 stmts=8 w.stmt.fam=80 w.own.move=6");
	let moves = 0;
	for (let seed = 1; seed < 41; seed++) {
		const lines = generate(seed as uint64, f).split("\n");
		for (let i = 0; i < lines.length; i++) {
			const at = lines[i].indexOf("move o");
			if (at < 0) { continue; }
			const name = ownNameAt(lines[i], at + 5);
			moves++;
			let declared = -1;
			for (let j = i - 1; j >= 0 && declared < 0; j--) {
				if (lines[j].trim().startsWith("let " + name + ":")) { declared = indentOf(lines[j]); }
			}
			assert declared == indentOf(lines[i]);
			for (let j = i + 1; j < lines.length && !lines[j].startsWith("}"); j++) {
				const k = lines[j].indexOf(name);
				assert k < 0 || ownNameAt(lines[j], k) != name;
			}
		}
	}
	assert moves > 20;
}

test "no ownership construct reaches a closure body" {
	const g = new Gen();
	g.rng = Rng.seeded(7 as uint64);
	g.tys = [Ty.Int32];
	g.fams = [Fam.Own];
	g.exprMax = 3;
	g.w = withWeights("w.expr.fam=100").w;
	g.ents = [
		{ kind: EntKind.OwnVar, name: "o0", ty: Ty.Int32, params: [], len: 0, cost: 0 as int64 },
		{ kind: EntKind.HeldVar, name: "h1", ty: Ty.Int32, params: [], len: 0, cost: 0 as int64 },
	];
	let outside = 0;
	for (let i = 0; i < 200; i++) {
		g.costCap = TOP_COST_CAP;
		g.cost = 0 as int64;
		g.nodesLeft = GEN_NODE_CAP;
		const body = g.lambda([Ty.Int32], Ty.Int32, 0, FN_COST_CAP).text;
		assert !body.contains("o0") && !body.contains("h1");
		const plain = g.expr(Ty.Int32, 0);
		if (plain.contains("o0") || plain.contains("h1")) { outside++; }
	}
	assert outside > 100;
}

test "each family alone reaches the program" {
	const closure = Features.defaults().overlay("fams=closure");
	const union = Features.defaults().overlay("fams=union");
	const generic = Features.defaults().overlay("fams=generic");
	assert closure.ok && union.ok && generic.ok;
	if (closure.ok && union.ok && generic.ok) {
		let c = false;
		let u = false;
		let g = false;
		for (let seed = 1; seed < 9; seed++) {
			if (generate(seed as uint64, closure.value).contains("(q")) { c = true; }
			if (generate(seed as uint64, union.value).contains("| string | null")) { u = true; }
			if (generate(seed as uint64, generic.value).contains("<T>")) { g = true; }
		}
		assert c && u && g;
	}
}

test "an exhausted budget emits one leaf for an expression or condition" {
	for (let seed = 1; seed < 21; seed++) {
		const g = new Gen();
		g.rng = Rng.seeded(seed as uint64);
		g.tys = [Ty.Int32, Ty.Float64];
		g.exprMax = 8;
		g.fams = [Fam.Closure, Fam.Union, Fam.Generic];
		g.expr(Ty.Int32, 0);
		g.cond(0);
		assert g.nodesLeft == GEN_NODE_CAP - 1;
		assert g.cost == (0 as int64);
	}
}

test "a named closure is invoked only when its weighted body fits" {
	for (const bodyCost of [0 as int64, FN_COST_CAP]) {
		let invoked = false;
		for (let seed = 1; seed < 41; seed++) {
			const g = new Gen();
			g.rng = Rng.seeded(seed as uint64);
			g.tys = [Ty.Int32];
			g.exprMax = 4;
			g.fams = [Fam.Closure];
			g.costCap = FN_COST_CAP;
			g.mult = 2 as int64;
			g.ents = [{ kind: EntKind.Callable, name: "c0", ty: Ty.Int32, params: [], len: 0, cost: bodyCost }];
			if (g.closureExpr(Ty.Int32, 0).contains("c0(")) { invoked = true; }
			assert g.cost <= g.costCap;
		}
		assert invoked == (bodyCost == (0 as int64));
	}
}

function countOf(text: string, needle: string): int32 {
	let n = 0;
	let at = text.indexOf(needle);
	while (at >= 0) {
		n++;
		at = text.indexOf(needle, at + needle.length);
	}
	return n;
}

function firstArg(call: string): string {
	let depth = 0;
	const open = call.indexOf("(");
	for (let i = open + 1; i < call.length; i++) {
		const c = call.slice(i, i + 1);
		if (c == "(") { depth++; }
		if (c == ")") { depth--; }
		if (depth == 0 && c == ",") { return call.slice(open + 1, i); }
	}
	return "";
}

test "a callback body may call a routine and is charged once per invocation" {
	let reached = false;
	for (let seed = 1; seed < 81; seed++) {
		const g = new Gen();
		g.rng = Rng.seeded(seed as uint64);
		g.tys = [Ty.Int32];
		g.exprMax = 3;
		g.fams = [Fam.Closure, Fam.Generic];
		g.costCap = FN_COST_CAP;
		g.fns = [{ name: "f0", ret: Ty.Int32, params: [], cost: 100 as int64 }];
		const text = g.famExpr(Ty.Int32, 0);
		const calls = countOf(text, "f0(");
		const twice = text.startsWith("twiceG<") ? countOf(firstArg(text), "f0(") : 0;
		if (calls > 0 && text.contains("=>")) { reached = true; }
		assert g.cost >= (((calls + twice) * 101) as int64);
		assert g.cost <= g.costCap;
	}
	assert reached;
}

test "a deferred closure body keeps its own budget" {
	let shaped = false;
	for (let seed = 1; seed < 21; seed++) {
		const g = new Gen();
		g.rng = Rng.seeded(seed as uint64);
		g.tys = [Ty.Int32];
		g.exprMax = 4;
		g.costCap = 0 as int64;
		const f = g.lambda([Ty.Int32], Ty.Int32, 0, FN_COST_CAP);
		if (f.cost > (0 as int64)) { shaped = true; }
		assert g.cost == (0 as int64) && g.costCap == (0 as int64) && g.mult == (1 as int64);
	}
	assert shaped;
}

test "the iter family alone reaches each of its shapes" {
	const f = withWeights("fams=iter types=int32,uint64,float64 stmts=8 w.stmt.fam=80 w.expr.fam=40");
	const shapes = ["\tfunction* y", "): Iterator<uint64> {", "): Iterator<float64> {", " => { a", "\t\tyield ", "\t\tfor (const x", "\tyield a",
		"for (const x", "{ break; }", ".next();", ".done || !r", ".value", "nthI(y", "lastI(y"];
	const seen: boolean[] = shapes.map((x: string): boolean => false);
	for (let seed = 1; seed < 41; seed++) {
		const text = generate(seed as uint64, f);
		for (let i = 0; i < shapes.length; i++) { if (text.contains(shapes[i])) { seen[i] = true; } }
	}
	for (let i = 0; i < shapes.length; i++) { assert seen[i]; }
}

test "a generator is declared only at a function's top level and its loop body holds no statement" {
	const f = withWeights("fams=iter stmts=8 w.stmt.fam=80 w.expr.fam=40 w.iter.decl=6");
	let gens = 0;
	for (let seed = 1; seed < 41; seed++) {
		const text = generate(seed as uint64, f);
		assert !text.contains("finally") && !text.contains("toItems");
		const lines = text.split("\n");
		for (let i = 0; i < lines.length; i++) {
			if (!lines[i].contains("function*")) { continue; }
			assert lines[i].startsWith("\tfunction* y");
			gens++;
			let j = i + 1;
			while (!lines[j].startsWith("\t\tfor (let i")) { j++; }
			for (j = j + 1; lines[j] != "\t\t}"; j++) {
				const t = lines[j].trim();
				assert t.startsWith("yield ") || t.startsWith("for (const x") || (t.contains(" = ") && !t.startsWith("let ") && !t.startsWith("const "));
			}
		}
	}
	assert gens > 20;
}

function seqFeatures(extra: string): Features {
	return withWeights("fams=seq stmts=8 w.stmt.fam=80 w.expr.fam=40 " + extra);
}

function gclsFeatures(extra: string): Features {
	return withWeights("fams=gcls stmts=8 w.stmt.fam=80 w.expr.fam=40 " + extra);
}

function textOver(f: Features, seeds: int32): string {
	let all = "";
	for (let seed = 1; seed <= seeds; seed++) { all += generate(seed as uint64, f); }
	return all;
}

function bothText(): string {
	return textOver(withWeights("fams=seq,gcls stmts=8 w.stmt.fam=80 w.expr.fam=40"), 60);
}

function reached(text: string, shapes: string[]): int32 {
	let missing = 0;
	for (const s of shapes) { if (!text.contains(s)) { missing++; } }
	return missing;
}

test "the seq family alone reaches each of its shapes" {
	const broad = textOver(seqFeatures("types=int32,uint8,float64"), 60);
	const shapes = ["pairT<", "swapT<", "firstQ<", "] = n", ": Vec<int32> = [", ": Vec<uint8> = v", "[] = v", ".slice(0, ", ").map((q",
		".length > 0 ? v", ".indexOf(", ".join(\",\").length", ".concat([", ".includes(",
		"spanAtInt32(v", "[0..", "[1..", "spanSetInt32(v", "readG<int32>(", "readG<uint8>(v",
		"[...v", ", ...v", "restVInt32(", "let [l", ", ...v", "pushQ<", "fillQ<Vec<", "fillQ<[", "headQ<",
		"takeQ<Vec<", ".set(move v", "for (const x", " of v", ".push(", ".pop();", ".splice(", ".fill(", ".setLength("];
	assert reached(broad, shapes) == 0;
	const same = textOver(seqFeatures("types=int32 w.seq.tuple=8 w.seq.ref=8"), 60);
	assert reached(same, ["swapQ<Vec<", "swapQ<[", "swapQ<int32>"]) == 0;
}

test "the gcls family alone reaches each of its shapes" {
	const broad = textOver(gclsFeatures("types=int32,uint8,float64"), 60);
	const shapes = ["new CellQ<", "idQ(", "idQ<CellQ<", ".map<", ".pairWith<", ".swap()", "bestQ<ItemQ<", "unwrapQ<", "unwrapQ<WrapQ<",
		"holdQ<", ".item", ".n)", "new StackQ<", ".top(", ".size()", "new ItemQ<", ".v.v", "new CellQ<CellQ<CellQ<", "fillQ<", "(out l",
		"roQ<CellQ<", "move z", "takeQ<Own", "swapQ<Own", ".drop();", ".set(", ".v = ", ".b = ", ".a = ", ".get().set(", ".get().get()",
		".key", "StackQ<Own", "CellQ<Own", ".swap().first()", ".first()"];
	assert reached(broad, shapes) == 0;
	const same = textOver(gclsFeatures("types=int32 w.gcls.decl=8 w.gcls.ref=8"), 60);
	assert reached(same, ["bestQ(", "swapQ<int32>(c", "swapQ<CellQ<"]) == 0;
}

test "a zero shape weight keeps its construct out of the program" {
	assert !textOver(seqFeatures("w.seq.borrow=0"), 30).contains("readG<");
	assert !textOver(seqFeatures("w.seq.span=0 w.seq.spanSet=0"), 30).contains("spanAtInt32(v");
	assert !textOver(seqFeatures("w.seq.span=0 w.seq.spanSet=0"), 30).contains("Set(v");
	const noBest = textOver(gclsFeatures("w.gcls.best=0"), 30);
	assert !noBest.contains("bestQ(") && !noBest.contains("bestQ<ItemQ<");
	const noOwn = textOver(gclsFeatures("w.gcls.own=0"), 30);
	assert !noOwn.contains("Own") && !noOwn.contains("ownHooks");
	assert textOver(gclsFeatures("w.gcls.own=8"), 30).contains("ownHooks");
}

test "a rest pattern puts one skip-raiser directive right after the head and cites its card" {
	let withRest = 0;
	let without = 0;
	for (let seed = 1; seed <= 30; seed++) {
		const text = generate(seed as uint64, seqFeatures("w.seq.rest=8"));
		const lines = text.split("\n");
		let rest = false;
		for (const line of lines) {
			const t = line.trim();
			if (t.startsWith("let [") && t.contains(", ...v")) { rest = true; }
		}
		assert countOf(text, "// @skip") == (rest ? 1 : 0);
		if (rest) {
			withRest++;
			assert lines[1].startsWith("// @skip-raiser: ");
			assert lines[1].contains("inbox/compiler/2026-10-17-raiser-has-no-host-bridge-for-msgenericarraypush");
		} else {
			without++;
		}
	}
	assert withRest > 10;
}

test "seq and gcls write no directive unless a rest pattern asks for it, and no program skips the JS lane" {
	assert !textOver(seqFeatures("w.seq.rest=0"), 40).contains("// @skip");
	assert !textOver(gclsFeatures(""), 40).contains("// @skip");
	assert !textOver(withWeights("w.fam.seq=0 w.fam.gcls=0"), 20).contains("raiser-has-no-host-bridge-for-msgenericarraypush");
	assert !bothText().contains("@skip-js");
}

test "a directive named twice is written once" {
	const g = new Gen();
	g.directive("// @skip-raiser: why");
	g.directive("// @skip-raiser: why");
	g.directive("// @skip-raiser: another");
	assert g.directives.length == 2;
}

test "a Vec push is refused once its length bound would pass the cap" {
	let pushed = false;
	for (const mult of [1000 as int64, 1 as int64]) {
		for (let seed = 1; seed <= 100; seed++) {
			const g = new Gen();
			g.rng = Rng.seeded(seed as uint64);
			g.tys = [Ty.Int32];
			g.exprMax = 1;
			g.costCap = TOP_COST_CAP;
			g.mult = mult;
			g.nodesLeft = GEN_NODE_CAP;
			g.ents = [{ kind: EntKind.VecVar, name: "v0", ty: Ty.Int32, params: [], len: 10, cost: 0 as int64 }];
			const text = g.seqVecEdit(Ty.Int32, "");
			if (text.contains(".push(")) { pushed = true; assert mult == (1 as int64); }
			assert g.ents[0].len <= SEQ_LEN_CAP;
			if (mult == (1 as int64) && text.contains(".push(")) { assert g.ents[0].len == 11; }
		}
	}
	assert pushed;
}

test "a moved Vec was declared in the moving block and is never named again" {
	const f = seqFeatures("types=int32,uint8 w.seq.move=8 w.seq.vec=6");
	let moves = 0;
	for (let seed = 1; seed < 41; seed++) {
		const lines = generate(seed as uint64, f).split("\n");
		for (let i = 0; i < lines.length; i++) {
			const at = lines[i].indexOf("move v");
			if (at < 0) { continue; }
			const name = ownNameAt(lines[i], at + 5);
			moves++;
			let declared = -1;
			for (let j = i - 1; j >= 0 && declared < 0; j--) {
				if (lines[j].trim().startsWith("let " + name + ":") || lines[j].contains("..." + name + "]")) { declared = indentOf(lines[j]); }
			}
			assert declared == indentOf(lines[i]);
			for (let j = i + 1; j < lines.length && !lines[j].startsWith("}"); j++) {
				const k = lines[j].indexOf(name);
				assert k < 0 || ownNameAt(lines[j], k) != name;
			}
		}
	}
	assert moves > 20;
}

test "no seq or gcls construct reaches a closure body" {
	const g = new Gen();
	g.rng = Rng.seeded(7 as uint64);
	g.tys = [Ty.Int32];
	g.fams = [Fam.Seq, Fam.Gcls];
	g.exprMax = 3;
	g.w = withWeights("w.expr.fam=100").w;
	const names = ["nq0", "vq1", "cq2", "zq4", "sq5", "kq6", "kq7"];
	g.ents = [
		{ kind: EntKind.TupleVar, name: "nq0", ty: Ty.Int32, params: [Ty.Int32, Ty.Int32], len: 2, cost: 0 as int64 },
		{ kind: EntKind.VecVar, name: "vq1", ty: Ty.Int32, params: [], len: 3, cost: 0 as int64 },
		{ kind: EntKind.CellVar, name: "cq2", ty: Ty.Int32, params: [], len: 0, cost: 0 as int64 },
		{ kind: EntKind.PairVar, name: "zq4", ty: Ty.Int32, params: [Ty.Int32, Ty.Int32], len: 0, cost: 0 as int64 },
		{ kind: EntKind.StackVar, name: "sq5", ty: Ty.Int32, params: [], len: 1, cost: 0 as int64 },
		{ kind: EntKind.ItemVar, name: "kq6", ty: Ty.Int32, params: [], len: 0, cost: 0 as int64 },
		{ kind: EntKind.ItemVar, name: "kq7", ty: Ty.Int32, params: [], len: 0, cost: 0 as int64 },
	];
	let outside = 0;
	for (let i = 0; i < 400; i++) {
		g.costCap = TOP_COST_CAP;
		g.cost = 0 as int64;
		g.nodesLeft = GEN_NODE_CAP;
		const body = g.lambda([Ty.Int32], Ty.Int32, 0, FN_COST_CAP).text;
		for (const n of names) { assert !body.contains(n); }
		const plain = g.expr(Ty.Int32, 0);
		for (const n of names) { if (plain.contains(n)) { outside++; } }
	}
	assert outside > 100;
}

test "a seq or gcls routine stays inside its cost bound" {
	const f = withWeights("w.expr.call=100 w.expr.fam=100 w.stmt.fam=100 w.stmt.let=100 w.stmt.for=100 w.stmt.if=100");
	for (let seed = 1; seed <= 12; seed++) {
		const g = new Gen();
		g.rng = Rng.seeded(seed as uint64);
		g.tys = [Ty.Int8, Ty.Int32];
		g.stmtMax = 32;
		g.depthMax = 8;
		g.exprMax = 8;
		g.tripMax = 64;
		g.fams = [Fam.Seq, Fam.Gcls];
		g.w = f.w;
		g.fn(0);
		g.fn(1);
		assert g.cost <= FN_COST_CAP;
		assert g.nodesLeft >= 0;
	}
}

test "no program nests a destructuring pattern, destructures an object or elides a slot" {
	const text = bothText();
	for (const shape of ["let [[", ", [l", "let {", "const {", "let [,", "[,", ", ,", "] = {"]) { assert !text.contains(shape); }
}

test "no program spreads a tuple, a Set or a Map, and every spread operand is a Vec" {
	const text = bothText();
	let at = text.indexOf("...");
	let spreads = 0;
	while (at >= 0) {
		spreads++;
		const next = text.slice(at + 3, at + 5);
		assert next == "xs" || (next.startsWith("v") && text.charCodeAt(at + 4) >= 48 && text.charCodeAt(at + 4) <= 57);
		at = text.indexOf("...", at + 3);
	}
	assert spreads > 20;
}

test "a spread argument always lands in the rest parameter of a variadic helper" {
	const text = textOver(seqFeatures("w.seq.spread=8"), 30);
	let calls = 0;
	for (const line of text.split("\n")) {
		if (!line.contains(" = restV") || line.startsWith("function")) { continue; }
		calls++;
		assert countOf(line, "...") == 1 && line.endsWith(");");
	}
	assert calls > 5;
}

test "a copied tuple is never written afterwards" {
	const f = withWeights("fams=seq types=int32 stmts=8 w.stmt.fam=80 w.seq.tuple=8 w.seq.tupleEdit=8 w.seq.ref=8");
	let copies = 0;
	for (let seed = 1; seed <= 40; seed++) {
		const lines = generate(seed as uint64, f).split("\n");
		for (let i = 0; i < lines.length; i++) {
			const t = lines[i].trim();
			const eq = t.lastIndexOf(" = n");
			if (!t.startsWith("let n") || !t.endsWith(";") || eq < 0 || t.contains("(")) { continue; }
			copies++;
			const names = [t.slice(4, t.indexOf(":")), t.slice(eq + 3, t.length - 1)];
			for (let j = i + 1; j < lines.length && !lines[j].startsWith("}"); j++) {
				const u = lines[j].trim();
				for (const name of names) {
					assert !(u.startsWith(name + "[") && u.contains("] = "));
					assert !u.contains("(out " + name + ",");
					assert !(u.contains("swapQ<[") && u.contains(name + ")")) && !(u.contains("swapQ<[") && u.contains("(" + name + ","));
				}
			}
		}
	}
	assert copies > 10;
}

test "no program names a shape that is parked behind an open compiler card" {
	const text = bothText();
	for (const shape of ["Record<", "[k: ", "{ [", "Cursor<", ".reverse()", ": readonly ", "setLength(-", "swapT(", "firstQ(", "pairT(", "readG(", "headQ(", "pushQ(", "fillQ(", "takeQ(", "roQ(", "unwrapQ(", "newWrapQ(", "holdQ("]) {
		assert !text.contains(shape);
	}
}

test "a move never feeds a constructor and a slice never feeds a Vec" {
	for (const line of bothText().split("\n")) {
		assert !(line.contains("new ") && line.contains("(move "));
		const rhs = line.slice(line.indexOf(" = ") + 3, line.length);
		const source = ownNameAt(rhs, 0);
		assert !(line.contains(": Vec<") && source != "" && rhs.startsWith(source + ".slice("));
	}
}

test "a borrow argument is always a variable, a field or an element" {
	const text = bothText();
	let at = text.indexOf("readG<");
	let borrows = 0;
	while (at >= 0) {
		const open = text.indexOf(">(", at);
		const c = text.charCodeAt(open + 2);
		if (text.charCodeAt(at - 1) != 32 || !text.slice(at - 9, at).startsWith("function")) {
			borrows++;
			assert c >= 97 && c <= 122;
		}
		at = text.indexOf("readG<", at + 6);
	}
	assert borrows > 20;
}

test "the enum family alone reaches each of its shapes" {
	const f = withWeights("fams=enum types=int32,uint8,float64 stmts=8 w.stmt.fam=80 w.expr.fam=40");
	const shapes = [
		"enum En", "selEn0", "mEn0",
		"BitSet<Fg", "bsFg0", ": BitSet<Fg0> = ", ".union(",
		"type Als", "alsId", "alsAt", "({ a: ", "({ v: ", "((q", ": Alc",
		"= distinct int32", "= distinct float64", "dsRankI([", "dsRankF([", ": DsI = ", ": DsF = ",
		"type Lt0 = \"", "cmpLt0(", "ifLt0(", "mwLt0(", "mxLt0(", ": Lt0 = ", " = nextLt0(",
		"type Dk0 =", "type Dm0 = match (kind: Kd0)", "type Db0 = match (ok: boolean)", "mkDk0(", ": Dk0 = ", ": Dm0 = ", ": Db0 = ",
		"): unknown {", ": unknown = mkCx(", "scoreCx(",
		"): never {", "const x: never = d;", "mustN(", "mustE(", "mustF(", "nvDk0(",
	];
	const floor = [1, 2, 2, 1, 2, 1, 1, 1, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 2, 1, 1, 2, 2, 2, 2];
	assert shapes.length == floor.length;
	const seen: boolean[] = shapes.map((x: string): boolean => false);
	for (let seed = 1; seed < 61; seed++) {
		const text = generate(seed as uint64, f);
		for (let i = 0; i < shapes.length; i++) { if (countOf(text, shapes[i]) >= floor[i]) { seen[i] = true; } }
	}
	for (let i = 0; i < shapes.length; i++) { assert seen[i]; }
}

test "an enum never repeats a value, so no match repeats a case label" {
	for (let seed = 1; seed <= 200; seed++) {
		const g = new Gen();
		g.rng = Rng.seeded(seed as uint64);
		g.numericType(0, 0);
		const seen: int32[] = [];
		let expected = 0;
		for (const line of g.helperText.split("\n")) {
			if (!line.startsWith("\tM")) { continue; }
			const body = line.slice(0, line.length - 1);
			const eq = body.indexOf(" = ");
			const value = eq < 0 ? expected : parseInt(body.slice(eq + 3, body.length)) as int32;
			for (const v of seen) { assert v != value; }
			seen.push(value);
			expected = value + 1;
		}
		assert seen.length >= 2;
	}
}

test "match arms hold identical or disjoint pattern sets" {
	let helpers = 0;
	for (let seed = 1; seed <= 60; seed++) {
		const g = new Gen();
		g.rng = Rng.seeded(seed as uint64);
		g.tys = [Ty.Int32];
		const et = g.enumType(EShape.Numeric);
		g.matchHelper(et, Ty.Int32);
		helpers++;
		const sets: string[][] = [];
		for (const line of g.helperText.split("\n")) {
			if (!line.startsWith("\t\t") || !line.contains(" => ") || line.startsWith("\t\t_")) { continue; }
			let head = line.slice(2, line.indexOf(" => "));
			if (head.contains(" when ")) { head = head.slice(0, head.indexOf(" when ")); }
			sets.push(head.split(" | "));
		}
		for (const a of sets) {
			for (const b of sets) {
				let shared = 0;
				for (const x of a) { if (b.includes(x)) { shared++; } }
				assert shared == 0 || (shared == a.length && shared == b.length);
			}
		}
	}
	assert helpers == 60;
}

test "the enum family emits no shape a compiler card parks" {
	const f = withWeights("fams=enum stmts=8 w.stmt.fam=80 w.expr.fam=40");
	for (const set of LIT_SETS) {
		for (const lit of set.split(",")) { assert lit.length > 0 && !"-0123456789".includes(lit.slice(0, 1)); }
	}
	for (let seed = 1; seed < 41; seed++) {
		const text = generate(seed as uint64, f);
		assert !text.contains("distinct string") && !text.contains("Map<Ds") && !text.contains("Set<Ds");
		assert !text.contains("Lt0[]") && !text.contains("Lt1[]") && !text.contains("Lt2[]");
		assert !text.contains("assertNever") && countOf(text, ": never = ") == countOf(text, "const x: never = d;");
		assert countOf(text, "const x: never = d;") <= countOf(text, "function nvDk0(d: Dk0)");
		assert !text.contains("(d == e)") && !text.contains("(d != e)") && !text.contains("(d === e)") && !text.contains("d.length");
	}
	const g = new Gen();
	g.rng = Rng.seeded(1 as uint64);
	g.enumKit(EShape.Distinct, 0);
	g.enumKit(EShape.Distinct, 1);
	for (const line of g.helperText.split("\n")) {
		const bare = line.replaceAll("(x as int32)", "").replaceAll("(x as float64)", "");
		for (const op of [" + x", "x + ", " - x", "x - ", " * x", "x * ", " / x", "x / ", " % x", "x % "]) { assert !bare.contains(op); }
	}
}

test "a family at weight zero keeps the stream of the others" {
	for (const f of ALL_FAMS) {
		const others: string[] = [];
		const all: string[] = [];
		for (const o of ALL_FAMS) {
			all.push(famName(o));
			if (o != f) { others.push(famName(o)); }
		}
		const off = withWeights("fams=" + all.join(",") + " w.fam." + famName(f) + "=0");
		const without = withWeights("fams=" + others.join(","));
		for (let seed = 1; seed <= 8; seed++) {
			const a = generate(seed as uint64, off);
			const b = generate(seed as uint64, without);
			assert a.slice(a.indexOf("\n"), a.length) == b.slice(b.indexOf("\n"), b.length);
		}
	}
}

test "the families added after own keep the seven-family stream at weight zero" {
	let zero = "";
	const first: string[] = [];
	for (const f of ALL_FAMS) {
		if (first.length < 7) { first.push(famName(f)); } else { zero += " w.fam." + famName(f) + "=0"; }
	}
	assert first[6] == "own";
	const off = withWeights(zero.trim());
	const without = withWeights("fams=" + first.join(","));
	for (let seed = 1; seed <= 20; seed++) {
		const a = generate(seed as uint64, off);
		const b = generate(seed as uint64, without);
		assert a.slice(a.indexOf("\n"), a.length) == b.slice(b.indexOf("\n"), b.length);
	}
}

const EXC_STMT_KEYS: string[] = ["catch", "finally", "rethrow", "unwind", "defer", "deferloop", "recover", "result", "narrow"];
const EXC_EXPR_KEYS: string[] = ["wrap", "orelse", "nullable"];
const EXC_STMT_MARKS: string[] = [".push(\"ok\");", ".push(\"F", ".push(\"after\");", "function excU", "defer ", ".push(\"d\" + String(i", ".push(\"r\" + d", "function excRs", "excMix(excDo"];
const EXC_EXPR_MARKS: string[] = ["excWInt32(", "(try excRsInt32", "excOrInt32(excNulInt32("];

function excOnly(key: string): Features {
	let isStmt = false;
	for (const k of EXC_STMT_KEYS) { if (k == key) { isStmt = true; } }
	let text = "fams=exc types=int32 stmts=8 w.stmt.fam=80 w.expr.fam=40";
	for (const k of isStmt ? EXC_STMT_KEYS : EXC_EXPR_KEYS) { if (k != key) { text += " w.exc." + k + "=0"; } }
	return withWeights(text);
}

function excKeys(): string[] {
	const out: string[] = [];
	for (const k of EXC_STMT_KEYS) { out.push(k); }
	for (const k of EXC_EXPR_KEYS) { out.push(k); }
	return out;
}

function excMarks(): string[] {
	const out: string[] = [];
	for (const k of EXC_STMT_MARKS) { out.push(k); }
	for (const k of EXC_EXPR_MARKS) { out.push(k); }
	return out;
}

function excFinallyHazard(lines: string[]): boolean {
	for (let i = 0; i < lines.length; i++) {
		const t = lines[i].trim();
		const next = i + 1 < lines.length ? lines[i + 1].trim() : "";
		if (t.contains("throw new ExcErr(\"fin\", 1)")) { return true; }
		if (t.startsWith("if (ixI(n") && (t.endsWith(", 4) == 1) { continue; }") || t.endsWith(", 4) == 1) { break; }"))) { return true; }
		if (t == "continue;" && next.startsWith("} finally {")) { return true; }
		if (t.startsWith("if (ixI(") && t.contains("{ throw ") && next.startsWith("} finally {")) { return true; }
	}
	return false;
}

function excDeferHazard(lines: string[]): boolean {
	for (const line of lines) {
		const t = line.trim();
		if (t.startsWith("if (ixI(n") && (t.contains(") == i") || t.contains(") == n")) && (t.endsWith("{ continue; }") || t.endsWith("{ break; }"))) { return true; }
	}
	return false;
}

test "the exc family alone reaches each of its shapes" {
	const keys = excKeys();
	const marks = excMarks();
	for (let i = 0; i < keys.length; i++) {
		const f = excOnly(keys[i]);
		let seen = false;
		for (let seed = 1; seed <= 40 && !seen; seed++) {
			const text = generate(seed as uint64, f);
			if (text.contains(marks[i])) { seen = true; }
			if (i < EXC_STMT_KEYS.length && keys[i] != "unwind") { assert !text.contains("function excU"); }
			if (i < EXC_STMT_KEYS.length && keys[i] != "narrow") { assert !text.contains("excMix(excDo"); }
		}
		assert seen;
	}
}

test "a zero exc family weight removes its helpers and its printed log" {
	const none = withWeights("fams=none");
	const exc = withWeights("fams=exc stmts=8 w.stmt.fam=80 w.expr.fam=40");
	for (let seed = 1; seed <= 8; seed++) {
		assert !generate(seed as uint64, none).contains("excLog");
		assert generate(seed as uint64, exc).contains("console.log(\"excLog \" + String(excLog));\n");
	}
}

test "a hazard shape carries its skip directive and every other shape carries none" {
	const keys = excKeys();
	for (let i = 0; i < keys.length; i++) {
		const f = excOnly(keys[i]);
		let hazardous = 0;
		for (let seed = 1; seed <= 60; seed++) {
			const text = generate(seed as uint64, f);
			const lines = text.split("\n");
			const fin = excFinallyHazard(lines);
			const def = excDeferHazard(lines);
			assert text.contains(EXC_SKIP_FINALLY + "\n") == fin;
			assert text.contains(EXC_SKIP_DEFER + "\n") == def;
			assert !text.contains("@skip-js");
			if (fin || def) {
				hazardous++;
				assert lines[1].startsWith("// @skip-raiser: ");
				let at = 1;
				while (lines[at].startsWith("// @")) { at++; }
				assert at == 1 + (fin ? 1 : 0) + (def ? 1 : 0);
				assert !lines[at].startsWith("//");
			}
		}
		const only = keys[i] == "finally" || keys[i] == "rethrow" || keys[i] == "deferloop" || keys[i] == "recover";
		if (only) { assert hazardous > 0 && hazardous < 60; }
		if (!only && i < EXC_STMT_KEYS.length) { assert hazardous == 0; }
	}
}

test "a directive line is kept once" {
	const g = new Gen();
	g.directive(EXC_SKIP_FINALLY);
	g.directive(EXC_SKIP_DEFER);
	g.directive(EXC_SKIP_FINALLY);
	assert g.directives.length == 2;
}

test "no exc construct throws from a constructor" {
	const f = withWeights("fams=exc stmts=8 w.stmt.fam=80 w.expr.fam=40");
	let constructors = 0;
	for (let seed = 1; seed <= 30; seed++) {
		let inCtor = false;
		for (const line of generate(seed as uint64, f).split("\n")) {
			if (line.contains("constructor(")) { inCtor = true; constructors++; }
			else if (inCtor && line == "\t}") { inCtor = false; }
			if (inCtor) { assert !line.contains("throw"); }
		}
	}
	assert constructors > 30;
}

test "no exc construct assigns a string to a union local" {
	const f = withWeights("fams=exc stmts=8 w.stmt.fam=80 w.expr.fam=40");
	let unions = 0;
	for (let seed = 1; seed <= 30; seed++) {
		for (const line of generate(seed as uint64, f).split("\n")) {
			if (!line.contains("| string | null")) { continue; }
			assert line.startsWith("function excBox");
			unions++;
		}
	}
	assert unions > 0;
}

test "no exc construct matches on a Result or puts a try in a match arm" {
	const f = withWeights("fams=exc stmts=8 w.stmt.fam=80 w.expr.fam=40 w.stmt.match=40");
	let arms = 0;
	let wrapped = 0;
	for (let seed = 1; seed <= 40; seed++) {
		for (const line of generate(seed as uint64, f).split("\n")) {
			const t = line.trim();
			assert !t.contains("{ ok");
			if (t.contains("match (n")) { assert false; }
			const first = t.length > 0 ? t.charCodeAt(0) : 0;
			const armLike = t.contains(" => ") && (t.startsWith("_ =>") || (first >= 48 && first <= 57) || t.startsWith("-"));
			if (!armLike) { continue; }
			arms++;
			assert !t.contains("try ");
			if (t.contains("excOe")) { wrapped++; }
		}
	}
	assert arms > 20 && wrapped > 0;
}

test "an exc statement is refused before it writes when the budget cannot hold it" {
	const g = new Gen();
	g.rng = Rng.seeded(1 as uint64);
	g.tys = [Ty.Int32];
	g.tripMax = 4;
	g.costCap = 5 as int64;
	assert g.excCatch("", 0) == "";
	assert g.excFinally("", 0) == "";
	assert g.excRethrow("", 0) == "";
	assert g.excUnwind("") == "";
	assert g.excDefer("", 0) == "";
	assert g.excDeferLoop("", 0) == "";
	assert g.excRecover("", 0) == "";
	assert g.excResultStmt(Ty.Int32, "") == "";
	assert g.excNarrowStmt(Ty.Int32, "") == "";
	assert g.excExpr(Ty.Int32, 0) == "" || g.cost <= g.costCap;
	assert g.helperText == "" && g.directives.length == 0;
}

test "exc statements restore scope, ents, the cost multiplier and the match-arm stack" {
	let helpers = 0;
	for (let seed = 1; seed <= 12; seed++) {
		const g = new Gen();
		g.rng = Rng.seeded(seed as uint64);
		g.tys = [Ty.Int8, Ty.Int32, Ty.Float64];
		g.stmtMax = 16;
		g.depthMax = 4;
		g.exprMax = 4;
		g.tripMax = 8;
		g.fams = [Fam.Exc];
		g.w = withWeights("fams=exc w.stmt.fam=80 w.expr.fam=40").w;
		g.fn(0);
		assert g.cost <= FN_COST_CAP;
		assert g.mult == (1 as int64);
		assert g.scope.length == g.fns[0].params.length;
		assert g.ents.length == 0;
		assert g.matchArms == 0;
		if (g.hasHelper("excBase")) { helpers++; }
	}
	assert helpers > 8;
}

test "the native family alone reaches each of its shapes" {
	const f = withWeights("fams=native types=int32,uint8,float64 stmts=8 w.stmt.fam=80 w.expr.fam=40");
	const shapes = [": NatSInt32 = { n: ", ": NatOUint8 = { head: ", ": NatSFloat64[] = [", " as Ptr<NatSInt32>;", "natPutInt32(", "\"ptr layout\"", "\"ptr neighbour\"", "\"ptr element\"",
		": Ref<NatSInt32> = { n: ", "natRefUint8(", ": Ref<NatSFloat64>[] = [", "\"ref identity\"",
		" as Span<int32> as Ptr<int32>;", ": Ptr<NatSInt32>[] = [", " += 1;", "\"arith distance\"", "\"arith back\"", "\"arith walk\"", "\"arith pointer array\"", ") - 0]",
		"natMalloc(", "natCalloc(", "natRealloc(", "natFree(", "\"heap kept\"", "\"heap zeroed\"",
		"natMemcpy(", "natMemmove(", "natMemset(", "\"libc memcmp differs\"",
		": cstring = \"", "natStrlen(", "natAtoi(", "natStrcmp(", " as string) == ", "\"cstr string\"",
		"natModf(", "natFrexp(", "natFrexpRef(", "natRandR(", "natLdexp(",
		"natFreeSink(", "natPushS(",
		"(sizeof NatSInt32 as ", "(sizeof NatOUint8 as ", "(sizeof int32 as ", "natBorrowInt32(", "natCursorUint8(", "natGetFloat64(", "[].m", "\"sink heap\""];
	const seen: boolean[] = shapes.map((x: string): boolean => false);
	for (let seed = 1; seed < 61; seed++) {
		const text = generate(seed as uint64, f);
		for (let i = 0; i < shapes.length; i++) { if (text.contains(shapes[i])) { seen[i] = true; } }
	}
	for (let i = 0; i < shapes.length; i++) { assert seen[i]; }
}

function usesHostShape(text: string): boolean {
	for (const tag of ["\"arith ", "\"heap ", "\"libc ", "\"cstr ", "\"out ", "\"sink "]) { if (text.contains(tag)) { return true; } }
	return false;
}

test "a program carries both host-lane skips right after its head exactly when it uses a shape those lanes cannot run" {
	const f = withWeights("fams=native types=int32,uint8,float64 stmts=6 w.stmt.fam=60");
	const hostFree = withWeights("fams=native types=int32,uint8,float64 stmts=6 w.stmt.fam=60 w.native.arith=0 w.native.heap=0 w.native.libc=0 w.native.cstr=0 w.native.out=0 w.native.sink=0");
	let skipped = 0;
	for (let seed = 1; seed <= 40; seed++) {
		const text = generate(seed as uint64, f);
		const lines = text.split("\n");
		assert usesHostShape(text);
		assert lines[1].startsWith("// @skip-js: ") && lines[2].startsWith("// @skip-raiser: ");
		assert countOf(text, "// @skip-js") == 1 && countOf(text, "// @skip-raiser") == 1;
		skipped++;
		const free = generate(seed as uint64, hostFree);
		assert !usesHostShape(free) && !free.contains("// @skip") && free.contains("natCheck(");
	}
	assert skipped == 40;
}

test "a program without the native family carries no host-lane skip and a directive is written once" {
	const f = withWeights("w.fam.native=0 stmts=6 w.stmt.fam=60");
	for (let seed = 1; seed <= 20; seed++) { const text = generate(seed as uint64, f); assert !text.contains(SKIP_JS) && !text.contains(SKIP_RAISER); }
	const g = new Gen();
	g.directive(SKIP_JS);
	g.directive(SKIP_JS);
	g.skipHostLanes();
	assert g.directives.length == 2 && g.directives[0] == SKIP_JS && g.directives[1] == SKIP_RAISER;
}

function nativeCorpus(): string[] {
	const f = withWeights("fams=native types=int32,float64 stmts=8 w.stmt.fam=80 w.expr.fam=40");
	const out: string[] = [];
	for (let seed = 1; seed <= 40; seed++) { out.push(generate(seed as uint64, f)); }
	return out;
}

test "parked: console.log never receives a cstring (inbox 2026-10-19-console-log-of-a-cstring-prints-object-on-c-and-js)" {
	let prints = 0;
	for (const text of nativeCorpus()) {
		for (const line of text.split("\n")) {
			if (!line.contains("console.log(")) { continue; }
			assert line.startsWith("console.log(\"g") || line.startsWith("console.log(\"e");
			prints++;
		}
	}
	assert prints > 100;
}

test "parked: no extern takes a function, which fails at clang (inbox 2026-10-19-a-function-passed-to-a-c-function-pointer-fails-at-clang)" {
	let externs = 0;
	for (const text of nativeCorpus()) {
		for (const line of text.split("\n")) {
			if (!line.startsWith("extern function ")) { continue; }
			assert !line.contains("=>");
			externs++;
		}
	}
	assert externs > 20;
}

test "parked: no program imports a header, which needs a project fixture" {
	for (const text of nativeCorpus()) { assert !text.contains("cimport") && !text.contains("import "); }
}

test "parked: a cstring is bound only to a literal or a named string (inbox 2026-10-19-a-cstring-reassigned-from-a-temporary-string-reads-freed-memory)" {
	let cstrings = 0;
	for (const text of nativeCorpus()) {
		for (const line of text.split("\n")) {
			const at = line.indexOf(": cstring = ");
			if (at < 0) { continue; }
			const rest = line.slice(at + ": cstring = ".length, line.length);
			assert line.trim().startsWith("const ") && (rest.startsWith("\"") || (!rest.contains("(") && !rest.contains("+"))) && rest.endsWith(";");
			cstrings++;
		}
	}
	assert cstrings > 10;
}

test "a module-level native statement borrows no array" {
	const f = withWeights("fams=native types=int32,float64 stmts=8 w.stmt.fam=80 w.expr.fam=40");
	let nested = 0;
	for (let seed = 1; seed <= 40; seed++) {
		for (const line of generate(seed as uint64, f).split("\n")) {
			if (!line.startsWith("\t") && !line.startsWith("function ") && !line.startsWith("struct ")) { assert !line.contains(" as Span<") && !line.contains("] = ["); }
			if (line.startsWith("\t") && line.contains(" as Span<")) { nested++; }
		}
	}
	assert nested > 0;
}

test "no native read or view reaches a closure body" {
	const names = ["n0", "z0", "z1", "n1"];
	let sizeofs = 0;
	let reads = 0;
	for (let seed = 1; seed <= 40; seed++) {
		const g = new Gen();
		g.rng = Rng.seeded(seed as uint64);
		g.tys = [Ty.Int32];
		g.exprMax = 4;
		g.fams = [Fam.Native];
		g.costCap = FN_COST_CAP;
		g.ents = [
			{ kind: EntKind.NatRec, name: "n0", ty: Ty.Int32, params: [], len: 0, cost: 0 as int64 },
			{ kind: EntKind.NatRecPtr, name: "z0", ty: Ty.Int32, params: [], len: 0, cost: 0 as int64 },
			{ kind: EntKind.NatPtr, name: "z1", ty: Ty.Int32, params: [], len: 4, cost: 1 as int64 },
			{ kind: EntKind.NatRef, name: "n1", ty: Ty.Int32, params: [], len: 0, cost: 0 as int64 },
		];
		const body = g.lambda([Ty.Int32], Ty.Int32, 0, FN_COST_CAP).text;
		for (const name of names) { assert !body.contains(name + "."); assert !body.contains(name + "["); assert !body.contains("(" + name + ","); assert !body.contains("(" + name + ")"); }
		if (body.contains("(sizeof ")) { sizeofs++; }
		const open = g.famExpr(Ty.Int32, 0);
		for (const name of names) { if (open.contains(name)) { reads++; } }
	}
	assert sizeofs > 0 && reads > 0;
}

test "a native pointer read stays inside the elements its provenance holds" {
	for (let seed = 1; seed <= 200; seed++) {
		const g = new Gen();
		g.rng = Rng.seeded(seed as uint64);
		g.tys = [Ty.Int32];
		g.exprMax = 2;
		g.costCap = FN_COST_CAP;
		g.ents = [{ kind: EntKind.NatPtr, name: "z1", ty: Ty.Int32, params: [], len: 4, cost: 2 as int64 }];
		const text = g.natRead(Ty.Int32, 0);
		if (text == "") { continue; }
		assert text.startsWith("z1[") && text.endsWith("]");
		const index = text.slice(3, text.length - 1);
		if (index.startsWith("ixI(")) {
			assert index.endsWith(", 6) - 2");
		} else {
			const i = index.parseInt() as int32;
			assert i >= -2 && i <= 3;
		}
	}
}

const SPAWN_KEYS: string[] = ["fan", "all", "move", "share", "locked", "arc", "nest", "fail", "timed"];
const SPAWN_MARKS: string[] = ["\t\ths.push(spawn(() => work", "await Promise.all(hs)", "{ move: [", "const ro: ", "new Locked(", "new Arc(",
	"const g = spawn(() => work", "throw new Error(\"bad\")", "{ timeout: 60000 }"];
const ACTOR_KEYS: string[] = ["state", "call", "chain", "many", "spawn", "stop"];
const ACTOR_MARKS: string[] = ["await a0.get0_", "await a0.bump_", "actor Sink", "const a1 = new Act", "actor Vault", "stop(a0.pid, ExitReason.Normal);"];
const RACE_KEYS: string[] = ["first", "tie", "any", "fail", "abort", "timer"];
const RACE_MARKS: string[] = ["const win = await Promise.race([ticks_", "const ns: int32[] = [", "Promise.any([", "(e as Error).message", "new AbortController()", "await sleepAsync("];

function onlyShape(fam: string, keys: string[], i: int32): Features {
	let text = "fams=" + fam;
	for (let k = 0; k < keys.length; k++) {
		if (k != i) { text += " w." + fam + "." + keys[k] + "=0"; }
	}
	return withWeights(text);
}

function reachesShapes(fam: string, keys: string[], marks: string[]): boolean {
	const all = withWeights("fams=" + fam);
	const seen: boolean[] = marks.map((x: string): boolean => false);
	for (let seed = 1; seed < 41; seed++) {
		const text = generate(seed as uint64, all);
		for (let i = 0; i < marks.length; i++) { if (text.contains(marks[i])) { seen[i] = true; } }
	}
	for (let i = 0; i < marks.length; i++) { if (!seen[i]) { return false; } }
	for (let i = 0; i < keys.length; i++) {
		const f = onlyShape(fam, keys, i);
		let found = false;
		for (let seed = 1; seed < 13; seed++) { if (generate(seed as uint64, f).contains(marks[i])) { found = true; } }
		if (!found) { return false; }
	}
	return true;
}

function entryLines(text: string): string {
	let out = "";
	for (const line of text.split("\n")) {
		if (line.startsWith("console.log(\"e")) { out += line + "\n"; }
	}
	return out;
}

function tiedTicks(text: string): boolean {
	for (const line of text.split("\n")) {
		if (!line.startsWith("\tconst ns: int32[] = [")) { continue; }
		const items = line.slice(line.indexOf("= [") + 3, line.lastIndexOf("]")).split(", ");
		if (items.length >= 2 && items[0] == items[1]) { return true; }
	}
	return false;
}

test "the spawn family alone reaches each of its shapes" {
	assert reachesShapes("spawn", SPAWN_KEYS, SPAWN_MARKS);
}

test "the actor family alone reaches each of its shapes" {
	assert reachesShapes("actor", ACTOR_KEYS, ACTOR_MARKS);
}

test "the race family alone reaches each of its shapes" {
	assert reachesShapes("race", RACE_KEYS, RACE_MARKS);
	const tie = onlyShape("race", RACE_KEYS, 1);
	let tied = false;
	for (let seed = 1; seed < 13; seed++) { if (tiedTicks(generate(seed as uint64, tie))) { tied = true; } }
	assert tied;
}

test "the statement families keep their stream whether or not a task family is on" {
	const on = withWeights("fams=closure,union,generic,agg,coll,str,own,iter,spawn,actor,race");
	const off = withWeights("fams=closure,union,generic,agg,coll,str,own,iter");
	for (let seed = 1; seed <= 20; seed++) {
		const a = generate(seed as uint64, on);
		const b = generate(seed as uint64, off);
		const aEnd = a.indexOf("\n}\n", a.indexOf("\nfunction f4(")) + 3;
		const bEnd = b.indexOf("\n}\n", b.indexOf("\nfunction f4(")) + 3;
		assert aEnd > 3 && bEnd > 3;
		assert a.slice(a.indexOf("\nlet g0"), aEnd) == b.slice(b.indexOf("\nlet g0"), bEnd);
		assert entryLines(a) == entryLines(b);
	}
}

test "a program of a task family has // @serial on its second line and no other program has it" {
	for (const fam of ["spawn", "actor", "race"]) {
		const f = withWeights("fams=" + fam);
		for (let seed = 1; seed <= 20; seed++) {
			const lines = generate(seed as uint64, f).split("\n");
			assert lines[1] == "// @serial";
		}
	}
	const plain = withWeights("fams=closure,agg");
	for (let seed = 1; seed <= 20; seed++) { assert !generate(seed as uint64, plain).contains("@serial"); }
}

test "a directive is emitted once and a skip names what the lane cannot run" {
	const g = new Gen();
	g.directive("// @serial");
	g.directive("// @serial");
	g.directive("// @skip-js: x");
	assert g.directives.length == 2;
	let locked = false;
	let actor = false;
	for (let seed = 1; seed < 41; seed++) {
		const spawn = generate(seed as uint64, onlyShape("spawn", SPAWN_KEYS, 4));
		if (spawn.contains("new Locked(")) { locked = true; assert spawn.contains("\n// @skip-js: Locked<T>") && spawn.contains("\n// @skip-raiser: "); }
		const act = generate(seed as uint64, onlyShape("actor", ACTOR_KEYS, 0));
		if (act.contains("actor Act")) { actor = true; assert act.contains("\n// @skip-raiser: ") && !act.contains("@skip-js"); }
	}
	assert locked && actor;
}

test "a task family keeps a task body to one printed summary after its comparison" {
	const f = withWeights("fams=spawn,actor,race");
	for (let seed = 1; seed < 41; seed++) {
		const text = generate(seed as uint64, f);
		const lines = text.split("\n");
		let inTask = false;
		for (const line of lines) {
			if (line.startsWith("async function task")) { inTask = true; }
			if (inTask) { assert !line.contains("console.log"); }
			if (line == "}") { inTask = false; }
			if (line.contains("console.log(") && line.startsWith("\t")) { assert line == "\tconsole.log(name + \" \" + par);"; }
		}
		assert countOf(text, "function taskCheck(") == 1;
	}
}

test "a 64-bit type never crosses a future or an actor reply" {
	const f = withWeights("fams=spawn,actor,race types=int64,uint64,int8");
	for (let seed = 1; seed < 41; seed++) {
		const text = generate(seed as uint64, f);
		assert !text.contains("Promise<int64>") && !text.contains("Promise<uint64>");
		assert !text.contains("): int64 { return this.st") && !text.contains("): uint64 { return this.st");
		assert !text.contains("st0: int64") && !text.contains("st0: uint64") && !text.contains("st1: int64") && !text.contains("st1: uint64");
		assert !text.contains("function work0(p0: int64") && !text.contains("function work0(p0: uint64");
	}
}

test "Promise.all joins only int32 and float64 results" {
	const f = withWeights("fams=spawn types=int8,uint8,int16,uint16,uint32 w.spawn.fan=0 w.spawn.move=0 w.spawn.share=0 w.spawn.locked=0 w.spawn.arc=0 w.spawn.nest=0 w.spawn.fail=0 w.spawn.timed=0");
	let joined = 0;
	for (let seed = 1; seed < 41; seed++) {
		const text = generate(seed as uint64, f);
		joined += countOf(text, "await Promise.all(hs)");
		assert !text.contains("const hs: Promise<int8>[]") && !text.contains("const hs: Promise<uint8>[]");
		assert !text.contains("const hs: Promise<int16>[]") && !text.contains("const hs: Promise<uint16>[]") && !text.contains("const hs: Promise<uint32>[]");
	}
	assert joined > 20;
}

test "a move is straight-line and its source is not read again" {
	let moves = 0;
	const f = onlyShape("spawn", SPAWN_KEYS, 2);
	for (let seed = 1; seed < 41; seed++) {
		const lines = generate(seed as uint64, f).split("\n");
		for (let i = 0; i < lines.length; i++) {
			if (!lines[i].contains("move: [")) { continue; }
			moves++;
			assert lines[i].startsWith("\tconst h = spawn(");
			const source = lines[i].contains("move: [arr]") ? "arr" : "c";
			for (let j = i + 1; lines[j] != "}"; j++) { assert !lines[j].contains(" " + source + ")") && !lines[j].contains("(" + source + ")") && !lines[j].contains(source + "."); }
		}
	}
	assert moves > 10;
}

test "a scenario function never returns early and a spawn handle is awaited on every path" {
	const f = withWeights("fams=spawn");
	for (let seed = 1; seed < 41; seed++) {
		let inTask = false;
		for (const line of generate(seed as uint64, f).split("\n")) {
			if (line.startsWith("async function task")) { inTask = true; }
			if (inTask) { assert !line.startsWith("\treturn ") && !line.startsWith("\t\treturn ") || line.contains("spawn("); }
			if (line == "}") { inTask = false; }
		}
	}
}

test "a timed spawn is fused with its await at the top level and never sits in async code" {
	let timed = 0;
	const f = onlyShape("spawn", SPAWN_KEYS, 8);
	for (let seed = 1; seed < 41; seed++) {
		let inTask = false;
		for (const line of generate(seed as uint64, f).split("\n")) {
			if (line.startsWith("async function task")) { inTask = true; }
			if (line.contains("timeout:")) {
				timed++;
				assert !inTask;
				assert line.startsWith("\tconst v") && line.contains(" = await spawn(");
			}
			if (line == "}") { inTask = false; }
		}
	}
	assert timed > 10;
}

test "an actor is neither created in a thunk nor captured by one nor messaged after stop" {
	const f = withWeights("fams=actor,spawn");
	for (let seed = 1; seed < 41; seed++) {
		const lines = generate(seed as uint64, f).split("\n");
		for (let i = 0; i < lines.length; i++) {
			const line = lines[i];
			if (line.contains("spawn(")) {
				assert !line.contains("new Act") && !line.contains("new Sink") && !line.contains("new Prod") && !line.contains("new Vault");
				assert !line.contains(".add_") && !line.contains(".put_") && !line.contains(".bump_") && !line.contains(".get0_") && !line.contains(".run_");
			}
			if (line.startsWith("\tstop(a")) {
				for (let j = i + 1; lines[j] != "}"; j++) { assert lines[j].startsWith("\tstop(a"); }
			}
		}
	}
}

test "an Arc payload is a plain numeric struct" {
	let arcs = 0;
	const f = onlyShape("spawn", SPAWN_KEYS, 5);
	for (let seed = 1; seed < 41; seed++) {
		const text = generate(seed as uint64, f);
		arcs += countOf(text, "new Arc(");
		for (const line of text.split("\n")) {
			if (line.startsWith("struct Payload")) { assert line.endsWith(" { n: int32; m: int32; }"); }
		}
	}
	assert arcs > 10;
}

test "no program asks for what the compiler cannot yet do" {
	const f = withWeights("fams=spawn,actor,race");
	for (let seed = 1; seed < 81; seed++) {
		const text = generate(seed as uint64, f);
		assert !text.contains("allSettled") && !text.contains("throwIfAborted") && !text.contains("Promise<string>");
		assert !text.contains("Promise<boolean>[]") && !text.contains("Promise<void>[]");
		assert !text.contains("generic actor") && !text.contains("actor Box<");
	}
}

test "the planted model differs from the real one by one term in every comparison" {
	const f = withWeights("fams=spawn,actor,race plant=model");
	const real = withWeights("fams=spawn,actor,race");
	for (let seed = 1; seed <= 20; seed++) {
		const planted = generate(seed as uint64, f);
		const text = generate(seed as uint64, real);
		assert planted.contains("function modelDelta(): int32 { return 1; }");
		assert !text.contains("modelDelta");
		let checks = 0;
		for (const line of planted.split("\n")) {
			if (line.startsWith("\ttaskCheck(")) {
				checks++;
				assert line.endsWith(" + String(modelDelta()));");
			}
		}
		assert checks > 0;
		assert countOf(planted, "taskCheck(\"task") == checks;
		assert !planted.contains("plantDelta");
	}
}

test "a planted model forces one scenario when no task family is on" {
	const f = withWeights("fams=none plant=model");
	for (let seed = 1; seed <= 5; seed++) {
		const text = generate(seed as uint64, f);
		assert text.split("\n")[1] == "// @serial";
		assert text.contains("async function task0()") && text.contains("+ String(modelDelta()));") && text.contains("await task0();");
	}
	const spawnOff = withWeights("w.fam.spawn=0 w.fam.actor=0 w.fam.race=0 plant=model");
	assert generate(3 as uint64, spawnOff).contains("await task0();");
}

test "no two actors of a program declare a method of the same name" {
	const f = withWeights("fams=actor");
	let actors = 0;
	for (let seed = 1; seed < 41; seed++) {
		const seen: string[] = [];
		let inActor = false;
		for (const line of generate(seed as uint64, f).split("\n")) {
			if (line.startsWith("actor ")) { inActor = true; actors++; }
			if (line == "}") { inActor = false; }
			if (!inActor || !line.startsWith("\t") || line.startsWith("\t\t") || line.startsWith("\tconstructor")) { continue; }
			const open = line.indexOf("(");
			if (open < 0) { continue; }
			const name = line.slice(1, open);
			if (name.contains(":")) { continue; }
			assert !seen.includes(name);
			seen.push(name);
		}
	}
	assert actors > 40;
}

test "a default program keeps the JS lane and runs in parallel" {
	for (let seed = 1; seed <= 30; seed++) {
		const text = generate(seed as uint64, Features.defaults());
		assert !text.contains("// @skip-js") && !text.contains("// @serial");
	}
}

const CLS_VECTOR = "fams=cls types=int32,uint8,float64 stmts=8 w.stmt.fam=80 w.expr.fam=40";

function clsShapeOf(t: string, i: int32): boolean {
	const stmt = t.startsWith("o") || t.startsWith("Cls");
	return match (i) {
		0 => t.startsWith("class Cls") && !t.contains(" extends ") && !t.contains(" implements "),
		1 => t.contains(" extends Cls"),
		2 => t.startsWith("super("),
		3 => t.startsWith("get pr"),
		4 => t.startsWith("set pr"),
		5 => t.startsWith("static s") && !t.startsWith("static sm"),
		6 => t.startsWith("static sm"),
		7 => t.startsWith("interface Ifc"),
		8 => t.contains(" implements Ifc"),
		9 => t.startsWith("private ") && t.contains("(") && !t.startsWith("private v"),
		10 => t.startsWith("protected "),
		11 => t.contains("readonly "),
		12 => t.contains(" instanceof Cls"),
		13 => t.startsWith("const o") && t.contains(": Ifc") && t.contains(" = new Cls"),
		14 => t.startsWith("const o") && t.contains(": Ifc") && t.contains(" = { "),
		15 => t.startsWith("const o") && t.contains(": Ifc") && !t.contains("new ") && !t.contains("{"),
		16 => t.startsWith("const o") && !t.contains(":") && !t.contains("new "),
		17 => t.startsWith("const z") && t.contains("[] = [new Cls"),
		18 => t.startsWith("for (const x") && t.contains(" of z"),
		19 => t.startsWith("Cls") && t.contains(".s") && t.contains(" = ") && !t.contains(".sm"),
		20 => t.startsWith("Cls") && t.contains(".sm") && t.endsWith(");"),
		21 => t.startsWith("o") && !t.startsWith("const") && t.contains(" = new Cls"),
		22 => stmt && t.contains(".v") && t.contains(" = ") && t.indexOf(".v") < t.indexOf(" = ") && t.indexOf(".v") < 8,
		23 => stmt && t.contains(".m") && t.endsWith(");") && !t.contains(" = ") && t.indexOf(".m") < 8,
		24 => stmt && t.contains(".pr") && t.contains(" = ") && t.indexOf(".pr") < t.indexOf(" = "),
		25 => stmt && t.contains(".u") && t.contains(" = ") && t.indexOf(".u") < t.indexOf(" = ") && t.indexOf(".u") < 8,
		26 => t.startsWith("ap") && t.contains(" => ") && t.contains(" = ("),
		27 => t.contains(".ap") && t.contains("(") && !t.startsWith("ap"),
		28 => t.contains("= new Cls") && t.contains(").v"),
		29 => t.contains(".pr") && t.contains("new Cls"),
		_ => false,
	};
}

const CLS_SHAPES: int32 = 30;

test "the cls family alone reaches each of its shapes" {
	const f = withWeights(CLS_VECTOR);
	const seen: boolean[] = [];
	for (let i = 0; i < CLS_SHAPES; i++) { seen.push(false); }
	for (let seed = 1; seed < 41; seed++) {
		for (const line of generate(seed as uint64, f).split("\n")) {
			const t = line.trim();
			for (let i = 0; i < CLS_SHAPES; i++) { if (clsShapeOf(t, i)) { seen[i] = true; } }
		}
	}
	for (let i = 0; i < CLS_SHAPES; i++) { assert seen[i]; }
}

function digitsAt(text: string, at: int32): int32 {
	let n = -1;
	for (let i = at; i < text.length; i++) {
		const c = text.charCodeAt(i);
		if (c < 48 || c > 57) { break; }
		n = (n < 0 ? 0 : n) * 10 + (c - 48);
	}
	return n;
}

function clsLines(text: string): string[] {
	const out: string[] = [];
	let inside = false;
	for (const line of text.split("\n")) {
		if (line.startsWith("class Cls")) { inside = true; }
		if (inside) { out.push(line); }
		if (line == "}") { inside = false; }
	}
	return out;
}

test "a zero cls weight keeps its construct out of every program" {
	const keys = ["w.cls.decl.inherit", "w.cls.decl.implements", "w.cls.decl.static", "w.cls.new", "w.cls.is", "w.cls.loop", "w.cls.literal", "w.cls.alias"];
	const needles = [" extends ", " implements ", "static ", " = new Cls", " instanceof ", "for (const x", " = { ", "const o"];
	for (let k = 0; k < keys.length; k++) {
		const f = withWeights(CLS_VECTOR + " " + keys[k] + "=0");
		for (let seed = 1; seed < 21; seed++) {
			const text = generate(seed as uint64, f);
			if (k == 3) {
				for (const line of text.split("\n")) { assert !line.trim().startsWith("const o") || !line.contains(" = new Cls"); }
			} else if (k == 7) {
				for (const line of text.split("\n")) {
					const t = line.trim();
					assert !(t.startsWith("const o") && !t.contains("new ") && !t.contains("{"));
				}
			} else if (k == 6) {
				for (const line of text.split("\n")) { assert !(line.trim().startsWith("const o") && line.contains(" = { ")); }
			} else {
				assert !text.contains(needles[k]);
			}
		}
	}
}

test "a program with a static class member skips the Raiser lane and no other program does" {
	const f = withWeights(CLS_VECTOR);
	let skipped = 0;
	let kept = 0;
	for (let seed = 1; seed < 41; seed++) {
		const text = generate(seed as uint64, f);
		const lines = text.split("\n");
		const marked = lines[1].startsWith("// @skip-raiser: ");
		assert marked == text.contains("\n\tstatic ");
		assert countOf(text, "@skip-raiser") == (marked ? 1 : 0);
		if (marked) { skipped++; } else { kept++; }
	}
	assert skipped > 5 && kept > 5;
	const none = withWeights("fams=none");
	assert !generate(1 as uint64, none).contains("@skip-");
}

test "a parked class construct never reaches a program" {
	const f = withWeights(CLS_VECTOR + " w.cls.decl.inherit=6 w.cls.decl.implements=6 w.cls.decl.accessor=6 w.cls.decl.static=6 w.cls.decl.visible=6");
	for (let seed = 1; seed < 41; seed++) {
		const text = generate(seed as uint64, f);
		assert !text.contains("super.") && !text.contains("override ") && !text.contains("abstract ");
		assert !text.contains("constructor(public") && !text.contains("constructor(private") && !text.contains("constructor(protected") && !text.contains("constructor(readonly");
		assert !text.contains(" | null") && !text.contains("ref ") && !text.contains("move ") && !text.contains("out ");
		assert !text.contains("<T>") && !text.contains("function*") && !text.contains("this.constructor");
		for (const line of text.split("\n")) {
			if (line.trim().startsWith("class Cls")) { assert line.startsWith("class Cls"); }
			assert !line.trim().startsWith("function ") || line.startsWith("function ");
		}
	}
}

test "an interface holds fields and function-typed fields and never a method signature" {
	const f = withWeights(CLS_VECTOR + " w.cls.decl.implements=6 w.cls.literal=6");
	let members = 0;
	for (let seed = 1; seed < 41; seed++) {
		let inside = false;
		for (const line of generate(seed as uint64, f).split("\n")) {
			if (line.startsWith("interface Ifc")) { inside = true; continue; }
			if (line == "}") { inside = false; }
			if (!inside) { continue; }
			const t = line.trim();
			const colon = t.indexOf(": ");
			assert colon > 0 && (t.indexOf("(") < 0 || t.indexOf("(") > colon) && t.endsWith(";");
			members++;
		}
	}
	assert members > 40;
}

test "an implementing class opens with its interface fields in the interface order" {
	const f = withWeights(CLS_VECTOR + " w.cls.decl.implements=6");
	let checked = 0;
	for (let seed = 1; seed < 41; seed++) {
		const lines = generate(seed as uint64, f).split("\n");
		for (let i = 0; i < lines.length; i++) {
			if (!lines[i].startsWith("interface Ifc")) { continue; }
			const name = lines[i].slice("interface ".length, lines[i].length - 2);
			const fields: string[] = [];
			for (let j = i + 1; lines[j] != "}"; j++) { fields.push(lines[j].trim().slice(0, lines[j].trim().indexOf(":"))); }
			for (let c = 0; c < lines.length; c++) {
				if (!lines[c].startsWith("class Cls") || !lines[c].endsWith(" implements " + name + " {")) { continue; }
				for (let k = 0; k < fields.length; k++) { assert lines[c + 1 + k].trim().startsWith(fields[k] + ":"); }
				checked++;
			}
		}
	}
	assert checked > 5;
}

test "a static member is a scalar with a literal initializer" {
	const f = withWeights(CLS_VECTOR + " w.cls.decl.static=6");
	let statics = 0;
	for (let seed = 1; seed < 41; seed++) {
		for (const line of generate(seed as uint64, f).split("\n")) {
			if (!line.startsWith("\tstatic s") || line.startsWith("\tstatic sm")) { continue; }
			const t = line.trim();
			const kind = t.slice(t.indexOf(": ") + 2, t.indexOf(" = "));
			assert kind == "int32" || kind == "uint8" || kind == "float64";
			const init = t.slice(t.indexOf(" = ") + 3, t.length);
			assert !init.contains("new ") && !init.contains("Cls") && !init.contains("g0") && !init.contains("this");
			statics++;
		}
	}
	assert statics > 20;
}

test "a constructor starts with super, reads neither this nor a field, and holds no arrow over this" {
	const f = withWeights(CLS_VECTOR + " w.cls.decl.inherit=6 w.cls.decl.visible=6");
	let ctors = 0;
	let supers = 0;
	for (let seed = 1; seed < 41; seed++) {
		const lines = clsLines(generate(seed as uint64, f));
		for (let i = 0; i < lines.length; i++) {
			if (!lines[i].startsWith("\tconstructor(")) { continue; }
			ctors++;
			if (lines[i + 1].trim().startsWith("super(")) { supers++; }
			for (let j = i + 1; lines[j] != "\t}"; j++) {
				const t = lines[j].trim();
				const at = t.startsWith("this.") ? t.indexOf(" = ") : 0;
				assert !t.slice(at, t.length).contains("this");
				if (t.contains("=> ")) { assert !t.contains("this"); }
			}
		}
		for (let i = 0; i < lines.length; i++) {
			if (lines[i].startsWith("class Cls") && lines[i].contains(" extends ")) {
				for (let j = i + 1; lines[j] != "}"; j++) {
					if (lines[j].startsWith("\tconstructor(")) { assert lines[j + 1].trim().startsWith("super("); }
				}
			}
		}
	}
	assert ctors > 20 && supers > 5;
}

function nestedArrow(line: string): boolean {
	const t = line.startsWith("ap") ? line.slice(line.indexOf(" = ") + 3, line.length) : line;
	let at = t.indexOf(" => ");
	while (at >= 0) {
		let depth = 0;
		for (let i = at + 4; i < t.length; i++) {
			const c = t.slice(i, i + 1);
			if (c == "(") { depth++; }
			if (c == ")") {
				if (depth == 0) { break; }
				depth--;
			}
			if (c == "," && depth == 0) { break; }
			if (t.slice(i, i + 4) == " => ") { return true; }
		}
		at = t.indexOf(" => ", at + 4);
	}
	return false;
}

test "a member body holds at most one arrow level" {
	const f = withWeights("fams=cls,closure,generic,coll types=int32,uint8,float64 stmts=8 expr=5 w.stmt.fam=80 w.expr.fam=60 w.fam.closure=40 w.fam.generic=40 w.fam.coll=20 w.cls.decl.accessor=6");
	let arrows = 0;
	for (let seed = 1; seed < 41; seed++) {
		for (const line of clsLines(generate(seed as uint64, f))) {
			const t = line.trim();
			assert !nestedArrow(t);
			arrows += countOf(t, " => ");
		}
	}
	assert arrows > 0;
}

test "a method calls only methods declared before it and reads one only through a call" {
	const f = withWeights(CLS_VECTOR + " w.cls.decl.inherit=6 w.cls.call=6");
	let calls = 0;
	for (let seed = 1; seed < 41; seed++) {
		const text = generate(seed as uint64, f);
		for (const line of clsLines(text)) {
			const t = line.trim();
			const own = t.startsWith("private m") || t.startsWith("protected m") ? t.indexOf("m") : 0;
			if (!t.slice(own, own + 1).startsWith("m") || digitsAt(t, own + 1) < 0) { continue; }
			const id = digitsAt(t, own + 1);
			let at = t.indexOf("this.m", own + 1);
			while (at >= 0) {
				const callee = digitsAt(t, at + 6);
				assert callee >= 0 && callee < id;
				calls++;
				at = t.indexOf("this.m", at + 6);
			}
		}
		let at = text.indexOf(".m");
		while (at >= 0) {
			const n = digitsAt(text, at + 2);
			if (n >= 0) { assert text.slice(at + 2 + String(n).length, at + 3 + String(n).length) == "("; }
			at = text.indexOf(".m", at + 2);
		}
	}
	assert calls > 5;
}

test "an instanceof narrows only the true branch of a ternary" {
	const f = withWeights(CLS_VECTOR + " w.cls.decl.inherit=6 w.cls.is=6");
	let tests = 0;
	for (let seed = 1; seed < 41; seed++) {
		const text = generate(seed as uint64, f);
		let at = text.indexOf(" instanceof Cls");
		while (at >= 0) {
			const after = at + " instanceof Cls".length;
			const n = digitsAt(text, after);
			assert n >= 0 && text.slice(after + String(n).length, after + String(n).length + 3) == " ? ";
			let from = at - 1;
			while (from > 0 && text.slice(from - 1, from) != "(") { from--; }
			assert text.slice(from - 1, from) == "(" && text.slice(from - 2, from - 1) != "!";
			tests++;
			at = text.indexOf(" instanceof Cls", after);
		}
	}
	assert tests > 10;
}

test "a class member keeps its id and its charged bound across an override" {
	let derived = 0;
	for (let seed = 1; seed <= 12; seed++) {
		const g = new Gen();
		g.rng = Rng.seeded(seed as uint64);
		g.tys = [Ty.Int32, Ty.Float64];
		g.stmtMax = 8;
		g.depthMax = 3;
		g.exprMax = 4;
		g.tripMax = 4;
		g.fams = [Fam.Cls];
		g.w = withWeights("w.cls.decl.inherit=6").w;
		g.fn(0);
		g.fn(1);
		if (g.classes.length > 1) { derived++; }
		for (const c of g.classes) {
			for (let i = 0; i < c.methods.length; i++) {
				assert c.methods[i].id == i && c.methods[i].cost == CLS_CAP * ((i + 1) as int64);
			}
		}
		assert g.clsBuilding == 0 && g.arrowDepth == 0 && g.mult == (1 as int64) && g.cost <= FN_COST_CAP;
		assert g.scope.length == g.fns[1].params.length && g.ents.length == 0;
	}
	assert derived > 0;
}

test "an object read by an instanceof test is never named inside a closure or nested routine body" {
	const g = new Gen();
	g.tys = [Ty.Int32, Ty.Uint8];
	g.fams = [Fam.Cls];
	g.exprMax = 3;
	g.costCap = TOP_COST_CAP;
	g.w = withWeights("w.cls.decl.inherit=100").w;
	for (let seed = 1; seed <= 6; seed++) {
		g.rng = Rng.seeded(seed as uint64);
		g.clsDecl(Ty.Int32);
	}
	assert g.classes.length > 2;
	g.ents = [{ kind: EntKind.ClsObj, name: "o0", ty: Ty.Int32, params: [], len: 0, cost: 2 as int64 }];
	let outside = 0;
	let named = 0;
	for (let seed = 1; seed <= 200; seed++) {
		g.rng = Rng.seeded(seed as uint64);
		g.nodesLeft = GEN_NODE_CAP;
		g.bodyDepth = 0;
		if (g.clsIsExpr(Ty.Int32, 0).contains(" instanceof ")) { outside++; }
		if (g.clsRecv(false, Ty.Int32, 0).text == "o0") { named++; }
		g.bodyDepth = 1;
		assert g.clsIsExpr(Ty.Int32, 0) == "";
		assert g.clsRecv(false, Ty.Int32, 0).text != "o0";
	}
	assert outside > 0 && named > 0;
}

function ternaryAtTop(line: string, from: int32, to: int32): boolean {
	let depth = 0;
	for (let i = from; i < to; i++) {
		const c = line.slice(i, i + 1);
		if (c == "(") { depth++; }
		if (c == ")") { depth--; }
		if (depth == 0 && line.slice(i, i + 3) == " ? ") { return true; }
	}
	return false;
}

function groupEnd(line: string, open: int32): int32 {
	let depth = 0;
	for (let i = open; i < line.length; i++) {
		const c = line.slice(i, i + 1);
		if (c == "(") { depth++; }
		if (c == ")") {
			depth--;
			if (depth == 0) { return i; }
		}
	}
	return line.length;
}

function freshReceiverUnderTernary(line: string): boolean {
	let at = line.indexOf("new Cls");
	while (at >= 0) {
		const ctorEnd = groupEnd(line, line.indexOf("(", at));
		if (line.slice(ctorEnd + 1, ctorEnd + 2) == ".") {
			const opens: int32[] = [];
			for (let i = 0; i < at; i++) {
				const c = line.slice(i, i + 1);
				if (c == "(") { opens.push(i); }
				if (c == ")") { opens.pop(); }
			}
			if (ternaryAtTop(line, 0, line.length)) { return true; }
			for (const o of opens) {
				if (ternaryAtTop(line, o + 1, groupEnd(line, o))) { return true; }
			}
		}
		at = line.indexOf("new Cls", at + 7);
	}
	return false;
}

test "a new temporary is read only at the root of an expression, never under a ternary" {
	const g = new Gen();
	g.tys = [Ty.Int32, Ty.Uint8];
	g.fams = [Fam.Cls];
	g.exprMax = 3;
	g.costCap = TOP_COST_CAP;
	for (let seed = 1; seed <= 4; seed++) {
		g.rng = Rng.seeded(seed as uint64);
		g.clsDecl(Ty.Int32);
	}
	g.ents = [];
	let roots = 0;
	for (let seed = 1; seed <= 100; seed++) {
		g.rng = Rng.seeded(seed as uint64);
		g.nodesLeft = GEN_NODE_CAP;
		assert g.clsRecv(false, Ty.Int32, 1).text == "";
		assert g.clsRecv(true, Ty.Int32, 2).text == "";
		if (g.clsRecv(false, Ty.Int32, 0).text.startsWith("new Cls")) { roots++; }
	}
	assert roots > 0;
	const f = withWeights("fams=cls types=int32,uint8 stmts=8 expr=5 w.stmt.fam=80 w.expr.fam=60");
	let tern = 0;
	for (let seed = 1; seed <= 40; seed++) {
		for (const line of generate(seed as uint64, f).split("\n")) {
			if (line.contains(" ? ")) {
				tern++;
				assert !freshReceiverUnderTernary(line);
			}
		}
	}
	assert tern > 0;
}

const CONV_SHAPES: string[] = ["cast", "frac", "text", "ext", "ref", "static", "proto", "op"];

function onlyConv(shape: string, fams: string): Features {
	let text = "fams=" + fams + " types=int8,int32,int64,uint8,uint64,float64 stmts=8 w.stmt.fam=80 w.expr.fam=40 w.expr.convert=0";
	for (const k of CONV_SHAPES) { text += " w.conv." + k + "=" + (k == shape ? "50" : "0"); }
	return withWeights(text);
}

function seenIn(text: string, alt: string): boolean {
	if (!alt.startsWith("^")) { return text.contains(alt); }
	const cut = alt.indexOf("~");
	const prefix = alt.slice(1, cut);
	const needle = alt.slice(cut + 1, alt.length);
	for (const line of text.split("\n")) {
		const t = line.trim();
		if (t.startsWith(prefix) && t.contains(needle)) { return true; }
	}
	return false;
}

function seenAny(text: string, alts: string): boolean {
	for (const alt of alts.split("|")) { if (seenIn(text, alt)) { return true; } }
	return false;
}

test "the conv family alone reaches each of its shapes" {
	const names = ["int8", "int32", "int64", "uint8", "uint64", "float64"];
	let nested = "";
	for (const a of names) {
		for (const b of names) { nested += (nested == "" ? "" : "|") + " as " + a + ") as " + b + ")"; }
	}
	const entries: string[] = [
		"cast=" + nested,
		"frac=convFloat64To",
		"frac=.25 as |.5 as |.75 as |.99 as |.01 as ",
		"text=parseInt(|.parseInt()",
		"text=parseFloat(|.parseFloat()",
		"text=Number(",
		"text=.toString(",
		"text=).length",
		"ext=.cvStep(",
		"ext=.cvPick(",
		"ext=).cvShift(",
		"ext=^let z~: CvS|^const v~new CvC",
		"ref=cvRun0",
		"ref=cvRun1",
		"ref=cvRun2",
		"ref=cvRun3",
		"ref=cvRun4",
		"ref=cvRun5",
		"ref=^z~.cvSwap();",
		"ref=^z~.cvShift(",
		"ref=^z~.cvBump(",
		"ref=^v~.cvBump(",
		"ref=^l~.cvBump(|^g~.cvBump(",
		"ref=^if (a~].cvBump(",
		"static=.cvOf(",
		"static=CvA",
		"static=.cvZero()",
		"static=^let z~.cvOf(|^const v~.cvOf(",
		"proto=toString(this s: CvS",
		"proto=cvFoldS",
		"proto=cvFoldC",
		"proto=cvMkV",
		"proto=cvMkK",
		"proto=cvMkD",
		"proto=^for (const x~ of z|^for (const x~ of v",
		"op= ** ",
		"op=(-CvS|((-z",
		"op=) + CvS",
		"op=) - CvS",
		"op= == CvS|< CvS",
		"op=^z~ = -z",
		"op=^z~ = z",
		"op=^l~ **= |^g~ **= ",
		"op=^l~ = (l|^g~ = (g",
	];
	for (const shape of CONV_SHAPES) {
		const f = onlyConv(shape, shape == "ref" ? "conv,coll" : "conv");
		const texts: string[] = [];
		for (let seed = 1; seed < 25; seed++) { texts.push(generate(seed as uint64, f)); }
		for (const entry of entries) {
			const eq = entry.indexOf("=");
			if (entry.slice(0, eq) != shape) { continue; }
			const alts = entry.slice(eq + 1, entry.length);
			let seen = false;
			for (const text of texts) { if (seenAny(text, alts)) { seen = true; } }
			assert seen;
		}
	}
}

test "conv weights stay capped and restore their scope" {
	for (let seed = 1; seed < 13; seed++) {
		const g = new Gen();
		g.rng = Rng.seeded(seed as uint64);
		g.tys = [Ty.Int8, Ty.Uint64, Ty.Float64];
		g.stmtMax = 32;
		g.depthMax = 8;
		g.exprMax = 8;
		g.tripMax = 64;
		g.fams = [Fam.Conv];
		g.fn(0);
		assert g.cost <= FN_COST_CAP;
		assert g.fns[0].cost <= FN_COST_CAP;
		assert g.mult == (1 as int64);
		assert g.scope.length == g.fns[0].params.length;
		assert g.ents.length == 0;
	}
}

function callsAFunction(text: string): boolean {
	for (let i = 1; i < text.length; i++) {
		if (text[i] != "(") { continue; }
		const before = text.charCodeAt(i - 1);
		if ((before >= 48 && before <= 57) || (before >= 65 && before <= 90) || (before >= 97 && before <= 122) || before == 95) { return true; }
	}
	return false;
}

test "a ref receiver is never followed by an argument that calls a function" {
	const f = onlyConv("ref", "conv,coll");
	let refs = 0;
	for (let seed = 1; seed < 41; seed++) {
		for (const line of generate(seed as uint64, f).split("\n")) {
			const t = line.trim();
			if (t.startsWith("function ")) { continue; }
			for (const open of [".cvBump(", ".cvSwap(", " **= "]) {
				const at = t.indexOf(open);
				if (at < 0) { continue; }
				const from = at + open.length;
				const end = open == " **= " ? t.indexOf(";", from) : t.indexOf(");", from);
				refs++;
				assert !callsAFunction(t.slice(from, end));
			}
			if (t.startsWith("z") && t.contains(".cvShift(")) {
				const from = t.indexOf(".cvShift(") + 9;
				refs++;
				assert !callsAFunction(t.slice(from, t.indexOf(");", from)));
			}
		}
	}
	assert refs > 40;
}

test "an argument of an extension with numeric overloads is never a ternary" {
	const parsed = withWeights("fams=none types=int32 expr=4 w.expr.leaf=1 w.expr.binary=0 w.expr.unary=0 w.expr.convert=0 w.expr.call=0 w.expr.ternary=99");
	const g = new Gen();
	g.rng = Rng.seeded(1 as uint64);
	g.tys = [Ty.Int32];
	g.exprMax = 4;
	g.w = parsed.w;
	let ternaries = 0;
	for (let i = 0; i < 40; i++) {
		g.cost = 0 as int64;
		g.costCap = FN_COST_CAP;
		if (g.expr(Ty.Int32, 0).contains(" ? ")) { ternaries++; }
		g.cost = 0 as int64;
		assert !g.cvArg(Ty.Int32, 0).contains(" ? ");
	}
	assert ternaries > 10;
}

function callArgs(text: string, from: int32): string[] {
	const out: string[] = [];
	let depth = 0;
	let start = from;
	for (let i = from; i < text.length; i++) {
		const c = text[i];
		if (c == "(") { depth++; }
		if (c == ")") {
			if (depth == 0) {
				out.push(text.slice(start, i));
				return out;
			}
			depth--;
		}
		if (c == "," && depth == 0) {
			out.push(text.slice(start, i));
			start = i + 1;
		}
	}
	return out;
}

function isTernary(arg: string): boolean {
	const a = arg.trim();
	if (!a.startsWith("(")) { return false; }
	let depth = 0;
	let found = false;
	for (let i = 0; i < a.length; i++) {
		const c = a[i];
		if (c == "(") { depth++; }
		if (c == ")") {
			depth--;
			if (depth == 0 && i < a.length - 1) { return false; }
		}
		if (depth == 1 && a.slice(i, i + 3) == " ? ") { found = true; }
	}
	return found;
}

test "no extension call over numeric overloads takes a ternary argument" {
	const f = onlyConv("ext", "conv,str,coll");
	let calls = 0;
	for (let seed = 1; seed < 41; seed++) {
		for (const line of generate(seed as uint64, f).split("\n")) {
			if (line.startsWith("function ")) { continue; }
			for (const open of [".cvStep(", ".cvPick("]) {
				let at = line.indexOf(open);
				while (at >= 0) {
					calls++;
					for (const arg of callArgs(line, at + open.length)) { assert !isTernary(arg); }
					at = line.indexOf(open, at + open.length);
				}
			}
		}
	}
	assert calls > 40;
}

test "a program declares the class generator toItems for one element type only" {
	const f = onlyConv("proto", "conv");
	let declared = 0;
	let structs = 0;
	for (let seed = 1; seed < 41; seed++) {
		const text = generate(seed as uint64, f);
		const generators = countOf(text, "function* toItems(");
		assert generators <= 1;
		declared += generators;
		if (countOf(text, "function toItems(this s: CvS") > 1) { structs++; }
	}
	assert declared > 5 && structs > 5;
}

test "a class temporary is held by a declaration or a helper, never inside a larger expression" {
	let temps = 0;
	for (const shape of ["ext", "static", "proto"]) {
		const f = onlyConv(shape, "conv");
		for (let seed = 1; seed < 41; seed++) {
			for (const line of generate(seed as uint64, f).split("\n")) {
				const text = line.trim();
				if (text.startsWith("function ") || text.startsWith("class ") || text.startsWith("type ")) { continue; }
				let at = line.indexOf("CvC");
				while (at >= 0) {
					const before = line.slice(0, at);
					if (before.endsWith("= ") || before.endsWith("= new ") || before.endsWith("return ")) { temps++; }
					else if (!text.startsWith("constructor") && text.indexOf(": CvC") < 0) { assert false; }
					at = line.indexOf("CvC", at + 3);
				}
			}
		}
	}
	assert temps > 40;
}
