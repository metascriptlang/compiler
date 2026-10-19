import { ALL_FAMS, Fam, Features, famName } from "./features";
import { generate } from "./gen";

export struct Shape {
	name: string;
	marker: string;
	min: int32;
}

export struct FamShapes {
	fam: Fam;
	vector: string;
	seeds: int32;
	shapes: Shape[];
}

const AGG_MARKS: string[] = [
	": PtS", " = mkS", "{ ...s", ".n = s",
	"\tsetS", " = new CellC", ".p = ", ".put(",
	".get()", "eqS", ".n.c", ".v = ",
];
const COLL_MARKS: string[] = [
	"[ixI(", ".pop(); }", ".splice(ixI(", ".setLength(",
	".fill(", ".reverse();", " = pushA", "[...a",
	", ...a", ".concat(", ").map(", "for (const x",
	"for (let j", "for (const [x", "let [l", ", ...r",
	"new Map<int32, ", "new Set<", " ?? ", ".delete(",
	".add(", ".has(", ".includes(", ".indexOf(",
	".join(\",\").length", "] = w",
];
const STR_MARKS: string[] = [
	".slice(", ".substring(", ".charAt(", "atS(",
	".toUpperCase()", ".toLowerCase()", ".trim()", ".trimStart()",
	".trimEnd()", ".repeat(", ".padStart(", ".padEnd(",
	".replace(", ".replaceAll(", ".split(", "String(",
	"${", ").length", ".indexOf(\"", ".lastIndexOf(\"",
	"codeS(", " == ", " != ", " < ",
	" > ", ".includes(", ".startsWith(", ".endsWith(",
	" += (", "let s", " as string)", "\\n",
	"\\\"", "中",
];
const OWN_MARKS: string[] = [
	"onDestroy(this o: OwnInt32)", "onCopy(this ref d: OwnUint8", ": OwnInt32 = mkO", ": OwnUint8 = o",
	" = move o", "= takeOInt32(move o", ".push(move o", "\tbumpO",
	"(out o", ": OwnInt32[] = [o", ".push(o", ".tag.length",
	"].v : ", ".v",
];
const ITER_MARKS: string[] = [
	"\tfunction* y", "): Iterator<uint64> {", "): Iterator<float64> {", " => { a",
	"\t\tyield ", "\t\tfor (const x", "\tyield a", "for (const x",
	"{ break; }", ".next();", ".done || !r", ".value",
	"nthI(y", "lastI(y",
];
const SEQ_MARKS: string[] = [
	"pairT<", "swapT<", "firstQ<", "] = n",
	": Vec<int32> = [", ": Vec<uint8> = v", "[] = v", ".slice(0, ",
	").map((q", ".length > 0 ? v", ".indexOf(", ".join(\",\").length",
	".concat([", ".includes(", "spanAtInt32(v", "[0..",
	"[1..", "spanSetInt32(v", "readG<int32>(", "readG<uint8>(v",
	"[...v", ", ...v", "restVInt32(", "let [l",
	", ...v", "pushQ<", "fillQ<Vec<", "fillQ<[",
	"headQ<", "takeQ<Vec<", ".set(move v", "for (const x",
	" of v", ".push(", ".pop();", ".splice(",
	".fill(", ".setLength(",
];
const GCLS_MARKS: string[] = [
	"new CellQ<", "idQ(", "idQ<CellQ<", ".map<",
	".pairWith<", ".swap()", "bestQ<ItemQ<", "unwrapQ<",
	"unwrapQ<WrapQ<", "holdQ<", ".item", ".n)",
	"new StackQ<", ".top(", ".size()", "new ItemQ<",
	".v.v", "new CellQ<CellQ<CellQ<", "fillQ<", "(out l",
	"roQ<CellQ<", "move z", "takeQ<Own", "swapQ<Own",
	".drop();", ".set(", ".v = ", ".b = ",
	".a = ", ".get().set(", ".get().get()", ".key",
	"StackQ<Own", "CellQ<Own", ".swap().first()", ".first()",
];
const ENUM_MARKS: string[] = [
	"enum En", "selEn0", "mEn0", "BitSet<Fg",
	"bsFg0", ": BitSet<Fg0> = ", ".union(", "type Als",
	"alsId", "alsAt", "({ a: ", "({ v: ",
	"((q", ": Alc", "= distinct int32", "= distinct float64",
	"dsRankI([", "dsRankF([", ": DsI = ", ": DsF = ",
	"type Lt0 = \"", "cmpLt0(", "ifLt0(", "mwLt0(",
	"mxLt0(", ": Lt0 = ", " = nextLt0(", "type Dk0 =",
	"type Dm0 = match (kind: Kd0)", "type Db0 = match (ok: boolean)", "mkDk0(", ": Dk0 = ",
	": Dm0 = ", ": Db0 = ", "): unknown {", ": unknown = mkCx(",
	"scoreCx(", "): never {", "const x: never = d;", "mustN(",
	"mustE(", "mustF(", "nvDk0(",
];
const NATIVE_MARKS: string[] = [
	": NatSInt32 = { n: ", ": NatOUint8 = { head: ", ": NatSFloat64[] = [", " as Ptr<NatSInt32>;",
	"natPutInt32(", "\"ptr layout\"", "\"ptr neighbour\"", "\"ptr element\"",
	": Ref<NatSInt32> = { n: ", "natRefUint8(", ": Ref<NatSFloat64>[] = [", "\"ref identity\"",
	" as Span<int32> as Ptr<int32>;", ": Ptr<NatSInt32>[] = [", " += 1;", "\"arith distance\"",
	"\"arith back\"", "\"arith walk\"", "\"arith pointer array\"", ") - 0]",
	"natMalloc(", "natCalloc(", "natRealloc(", "natFree(",
	"\"heap kept\"", "\"heap zeroed\"", "natMemcpy(", "natMemmove(",
	"natMemset(", "\"libc memcmp differs\"", ": cstring = \"", "natStrlen(",
	"natAtoi(", "natStrcmp(", " as string) == ", "\"cstr string\"",
	"natModf(", "natFrexp(", "natFrexpRef(", "natRandR(",
	"natLdexp(", "natFreeSink(", "natPushS(", "(sizeof NatSInt32 as ",
	"(sizeof NatOUint8 as ", "(sizeof int32 as ", "natBorrowInt32(", "natCursorUint8(",
	"natGetFloat64(", "[].m", "\"sink heap\"",
];
const META_MARKS: string[] = [
	"(@comptime { return ", "(@comptime { let a", "=> { let a", "@comptime function metaFn",
	"function metaPlain", "macro metaBin", "macro metaPick", "macro metaTwice",
	"macro metaNest", "macro metaFold", "macro metaChain", "macro metaStrLen",
	"macro metaHoist", "(node: Node): Node {\n\tlet acc: Node = quote {", "metaJsxS(<", " {...metaProp", "isPlainData<U>()",
	"@inline function metaInl", "@noinline function metaInl", "\twhen (", " else when (",
	" else { l", "metaChkInt32(", "metaShowInt32(", "metaShowStr(",
	").length; }) as ", "\", (@comptime { return ", " {...{}}", "macro metaDescribe",
	"@metaDescribe\nclass MetaD", "macro metaScale", "macro metaPlus", "ClassFieldDecoratorContext",
];
const ASYNC_MARKS: string[] = [
	"\nasync function a", "\nconst a", " = async (p0: int32, p1: string): Promise<", "\n\tasync m(p0: int32, p1: string): Promise<",
	"\tawait Promise.resolve(0);\n", " = await Promise.resolve(", " = await pr", "await Promise.all([",
	"} catch (z", "await Promise.reject<", "(await a", ".n.d = ",
	".push(", ".v = ", " = async (q", "throw new Error(",
	"\"re:\"", "Promise<Result<",
];
const ENUM_FLOORS: int32[] = [1, 2, 2, 1, 2, 1, 1, 1, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 2, 1, 1, 2, 2, 2, 2];

const CLS_MARKS: string[] = ["class Cls", " extends Cls", "super(", "get pr", "set pr", "static sm", "interface Ifc", " implements Ifc", "protected ", "readonly ", " instanceof Cls"];
const CONV_KEYS: string[] = ["cast", "frac", "text", "ext", "ref", "static", "proto", "op"];
const CONV_MARKS: string[] = [" as int32) as int64)", "convFloat64To", ".toString(", ".cvStep(", "cvRun0", ".cvOf(", "cvFoldS", ") + CvS"];
const EXC_KEYS: string[] = ["catch", "finally", "rethrow", "unwind", "defer", "deferloop", "recover", "result", "narrow", "wrap", "orelse", "nullable"];
const EXC_MARKS: string[] = [".push(\"ok\");", ".push(\"F", ".push(\"after\");", "function excU", "defer ", ".push(\"d\" + String(i", ".push(\"r\" + d", "function excRs", "excMix(excDo", "excWInt32(", "(try excRsInt32", "excOrInt32(excNulInt32("];
const SPAWN_KEYS: string[] = ["fan", "all", "move", "share", "locked", "arc", "nest", "fail", "timed"];
const SPAWN_MARKS: string[] = ["\t\ths.push(spawn(() => work", "await Promise.all(hs)", "{ move: [", "const ro: ", "new Locked(", "new Arc(", "const g = spawn(() => work", "throw new Error(\"bad\")", "{ timeout: 60000 }"];
const ACTOR_KEYS: string[] = ["state", "call", "chain", "many", "spawn", "stop"];
const ACTOR_MARKS: string[] = ["await a0.get0_", "await a0.bump_", "actor Sink", "const a1 = new Act", "actor Vault", "stop(a0.pid, ExitReason.Normal);"];
const RACE_KEYS: string[] = ["first", "tie", "any", "fail", "abort", "timer"];
const RACE_MARKS: string[] = ["const win = await Promise.race([ticks_", "const ns: int32[] = [", "Promise.any([", "(e as Error).message", "new AbortController()", "await sleepAsync("];

function listed(marks: string[]): Shape[] { return marks.map((m: string): Shape => ({ name: m, marker: m, min: 1 })); }

function floored(marks: string[], floors: int32[]): Shape[] {
	if (marks.length != floors.length) { unreachable; }
	const out: Shape[] = [];
	for (let i = 0; i < marks.length; i++) { out.push({ name: marks[i], marker: marks[i], min: floors[i] }); }
	return out;
}

function keyed(keys: string[], marks: string[]): Shape[] {
	if (keys.length != marks.length) { unreachable; }
	const out: Shape[] = [];
	for (let i = 0; i < keys.length; i++) { out.push({ name: keys[i], marker: marks[i], min: 1 }); }
	return out;
}

const STD: string = " stmts=8 w.stmt.fam=80 w.expr.fam=40";

export function shapesOf(fam: Fam): FamShapes {
	return match (fam) {
		Fam.Closure => shaped(fam, "fams=closure", 8, listed(["(q"])),
		Fam.Union => shaped(fam, "fams=union", 8, listed(["| string | null"])),
		Fam.Generic => shaped(fam, "fams=generic", 8, listed(["<T>"])),
		Fam.Agg => shaped(fam, "fams=agg types=int32,uint8 stmts=8 w.stmt.fam=80", 40, listed(AGG_MARKS)),
		Fam.Coll => shaped(fam, "fams=coll types=int32,uint8 stmts=8 w.stmt.fam=80", 40, listed(COLL_MARKS)),
		Fam.Str => shaped(fam, "fams=str types=int32,uint8 stmts=8 w.stmt.fam=80", 40, listed(STR_MARKS)),
		Fam.Own => shaped(fam, "fams=own types=int32,uint8 stmts=8 w.stmt.fam=80", 40, listed(OWN_MARKS)),
		Fam.Iter => shaped(fam, "fams=iter types=int32,uint64,float64" + STD, 40, listed(ITER_MARKS)),
		Fam.Seq => shaped(fam, "fams=seq types=int32,uint8,float64" + STD, 60, listed(SEQ_MARKS)),
		Fam.Gcls => shaped(fam, "fams=gcls types=int32,uint8,float64" + STD, 60, listed(GCLS_MARKS)),
		Fam.Enum => shaped(fam, "fams=enum types=int32,uint8,float64" + STD, 60, floored(ENUM_MARKS, ENUM_FLOORS)),
		Fam.Exc => shaped(fam, "fams=exc types=int32" + STD, 40, keyed(EXC_KEYS, EXC_MARKS)),
		Fam.Native => shaped(fam, "fams=native types=int32,uint8,float64" + STD, 60, listed(NATIVE_MARKS)),
		Fam.Spawn => shaped(fam, "fams=spawn", 40, keyed(SPAWN_KEYS, SPAWN_MARKS)),
		Fam.Actor => shaped(fam, "fams=actor", 40, keyed(ACTOR_KEYS, ACTOR_MARKS)),
		Fam.Race => shaped(fam, "fams=race", 40, keyed(RACE_KEYS, RACE_MARKS)),
		Fam.Cls => shaped(fam, "fams=cls types=int32,uint8,float64" + STD, 40, listed(CLS_MARKS)),
		Fam.Conv => shaped(fam, "fams=conv,coll types=int8,int32,int64,uint8,uint64,float64 w.expr.convert=0" + STD, 60, keyed(CONV_KEYS, CONV_MARKS)),
		Fam.Meta => shaped(fam, "fams=meta types=int32,uint8,float64" + STD, 40, listed(META_MARKS)),
		Fam.Async => shaped(fam, "fams=async types=int32,uint64,float64" + STD, 40, listed(ASYNC_MARKS)),
	};
}

function shaped(fam: Fam, vector: string, seeds: int32, shapes: Shape[]): FamShapes {
	return { fam: fam, vector: vector, seeds: seeds, shapes: shapes };
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

export function hitCounts(texts: string[], shapes: Shape[]): int32[] {
	const out: int32[] = shapes.map((s: Shape): int32 => 0);
	for (const text of texts) {
		for (let i = 0; i < shapes.length; i++) { if (countOf(text, shapes[i].marker) >= shapes[i].min) { out[i]++; } }
	}
	return out;
}

function shown(name: string): string {
	return "\"" + name.replaceAll("\n", "\\n").replaceAll("\t", "\\t") + "\"";
}

export function hitLines(fams: Fam[], texts: string[]): string[] {
	const lines: string[] = [];
	for (const fam of fams) {
		const shapes = shapesOf(fam).shapes;
		const counts = hitCounts(texts, shapes);
		let reached = 0;
		let list = "";
		for (let i = 0; i < shapes.length; i++) {
			if (counts[i] > 0) { reached++; }
			list += " " + shown(shapes[i].name) + "=" + String(counts[i]);
		}
		lines.push("  hits " + famName(fam) + " " + String(reached) + "/" + String(shapes.length) + ":" + list);
	}
	return lines;
}

test "a hit counts the programs holding the marker, not its occurrences" {
	const shapes: Shape[] = [{ name: "a", marker: "aa", min: 1 }, { name: "b", marker: "bb", min: 2 }, { name: "c", marker: "cc", min: 1 }];
	const counts = hitCounts(["aa aa bb", "bb bb aa", "x"], shapes);
	assert counts.length == 3 && counts[0] == 2 && counts[1] == 1 && counts[2] == 0;
}

test "a family's hit line names every shape with its count and the reached total" {
	const lines = hitLines([Fam.Closure, Fam.Union], ["(q0", "(q1 | string | null", "none"]);
	assert lines.length == 2;
	assert lines[0] == "  hits closure 1/1: \"(q\"=2";
	assert lines[1] == "  hits union 1/1: \"| string | null\"=1";
	const shapes = hitLines([Fam.Spawn], ["\t\ths.push(spawn(() => work"]);
	assert shapes[0].startsWith("  hits spawn 1/9: \"fan\"=1 \"all\"=0");
	assert hitLines([], ["x"]).length == 0;
}

test "every family has a table whose shapes its own vector reaches" {
	for (const fam of ALL_FAMS) {
		const t = shapesOf(fam);
		const r = Features.defaults().overlay(t.vector);
		assert r.ok;
		if (!r.ok) { continue; }
		const texts: string[] = [];
		for (let seed = 1; seed <= t.seeds; seed++) { texts.push(generate(seed as uint64, r.value)); }
		const counts = hitCounts(texts, t.shapes);
		for (let i = 0; i < t.shapes.length; i++) {
			if (counts[i] == 0) { console.log("unreached " + famName(fam) + " " + t.shapes[i].name); }
			assert counts[i] > 0;
		}
	}
}
