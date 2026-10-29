import { compileProjectToC, MapEntry } from "../helpers";
import { setParserDefines, resetParserDefines } from "../../parser/context";
import { createDefineTable, applyDefineSwitch } from "../../compiler/defines";

const HEADER = "test/cFunctionPointer/sort.h";
const MAIN = "test/cFunctionPointer/main.ms";
const SORT = "typedef int (*Compare)(const void *, const void *);\n"
	+ "void sortAll(void *base, unsigned long count, Compare compare);\n"
	+ "void eachIndex(int count, void (*visit)(int));\n"
	+ "typedef int (*Unary)(int);\n"
	+ "typedef struct Holder { Unary op; int k; } Holder;\n"
	+ "typedef struct Table { Unary fs[2]; int k; } Table;\n"
	+ "Table makeTable(void);\n"
	+ "int setOpt(int option, const void *value);\n";

function compileC(main: string): string {
	const t = createDefineTable();
	applyDefineSwitch(t, "-d:c");
	applyDefineSwitch(t, "-d:backend=c");
	setParserDefines(t);
	const entries: MapEntry[] = [{ entryPath: HEADER, entrySource: SORT }, { entryPath: MAIN, entrySource: main }];
	const out = compileProjectToC(entries, MAIN);
	resetParserDefines();
	return out;
}

const IMPORT = "import { sortAll, eachIndex } from \"./sort.h\";\nconst xs: int32[] = [2, 1];\n";

test "C: a top-level function reaches a header's function pointer as its C symbol" {
	const c = compileC(IMPORT + "function byValue(a: Ptr<void> | null, b: Ptr<void> | null): int32 { return 0; }\n"
		+ "function show(i: int32): void { console.log(i); }\n"
		+ "sortAll(xs as Ptr<void>, 2, byValue);\neachIndex(2, show);\n");
	assert !c.startsWith("ERROR"), c;
	assert !c.contains("msClosure){ .fn = (void*)byValue"), c;
	assert !c.contains("msClosure){ .fn = (void*)show"), c;
}

test "C: a capturing closure into a header's function pointer is refused" {
	const c = compileC(IMPORT + "let seen: int32 = 0;\neachIndex(2, (i: int32): void => { seen += i; });\n");
	assert c.startsWith("ERROR"), c;
	assert c.contains("'eachIndex' parameter 'visit' is a C function pointer"), c;
}

test "C: a closure into a header's typedef'd function pointer is refused by name" {
	const c = compileC(IMPORT + "let bias: int32 = 1;\nsortAll(xs as Ptr<void>, 2, (a: Ptr<void> | null, b: Ptr<void> | null): int32 => bias);\n");
	assert c.contains("'sortAll' parameter 'compare' is a C function pointer"), c;
}

test "C: a function whose parameter width differs from the C pointer's is refused" {
	const c = compileC(IMPORT + "function show(i: int64): void { console.log(i); }\neachIndex(2, show);\n");
	assert c.startsWith("ERROR"), c;
	assert c.contains("eachIndex"), c;
}

const HOLDER = "import { Holder } from \"./sort.h\";\nfunction twice(n: int32): int32 { return n * 2; }\n";

test "C: a header struct's function-pointer field is a plain pointer, called directly and given no closure hook" {
	const c = compileC(HOLDER + "let h: Holder = { op: twice, k: 3 };\nh.op = twice;\nconsole.log(h.op(21));\n");
	assert !c.startsWith("ERROR"), c;
	assert c.contains(".op(21)"), c;
	assert !c.contains(".op(int32_t);"), c;
	assert !c.contains("msClosureWasMoved"), c;
	assert !c.contains("msClosure){ .fn = (void*)twice"), c;
}

test "C: a closure into a header struct's function-pointer field is refused" {
	const c = compileC(HOLDER + "let k: int32 = 3;\nconst h: Holder = { op: (n: int32): int32 => n + k, k: 1 };\n");
	assert c.startsWith("ERROR"), c;
	assert c.contains("is not assignable to a C function pointer"), c;
}

test "C: a closure assigned to a header struct's function-pointer field is refused" {
	const c = compileC(HOLDER + "let h: Holder = { op: twice, k: 1 };\nlet k: int32 = 3;\nh.op = (n: int32): int32 => n + k;\n");
	assert c.startsWith("ERROR"), c;
	assert c.contains("is not assignable to a C function pointer"), c;
}

const TABLE = "import { Table, makeTable } from \"./sort.h\";\nfunction twice(n: int32): int32 { return n * 2; }\n";

test "C: a header struct's array of function pointers is a plain pointer typedef, called directly" {
	const c = compileC(TABLE + "let t = makeTable();\nt.fs[0] = twice;\nconsole.log(t.fs[0](5));\n");
	assert !c.startsWith("ERROR"), c;
	assert c.contains("typedef int32_t(*msFnPtr_"), c;
	assert !c.contains("msSizedArray_msClosure"), c;
	assert !c.contains("msClosureDestroy"), c;
}

test "C: a closure assigned to an element of a header struct's function-pointer array is refused" {
	const c = compileC(TABLE + "let t = makeTable();\nlet k: int32 = 3;\nt.fs[1] = (n: int32): int32 => n + k;\n");
	assert c.startsWith("ERROR"), c;
	assert c.contains("is not assignable to a C function pointer"), c;
}

test "C: a function-pointer binding cast to Ptr<void> is the pointer's value, not its address" {
	const c = compileC("import { Unary, setOpt } from \"./sort.h\";\nfunction twice(n: int32): int32 { return n * 2; }\nconst u: Unary = twice;\nsetOpt(1, u as Ptr<void>);\n");
	assert !c.startsWith("ERROR"), c;
	assert !c.contains("(void*)&"), c;
}

const CAST = "import { Unary, setOpt } from \"./sort.h\";\nfunction add(n: int32): int32 { return n + 1; }\nlet k: int32 = 3;\n";

test "C: a closure cast to Ptr<void> is refused" {
	const c = compileC(CAST + "const lam = (n: int32): int32 => n + k;\nsetOpt(1, lam as Ptr<void>);\n");
	assert c.startsWith("ERROR"), c;
	assert c.contains("a closure carries an environment"), c;
}

test "C: a closure held in a typed binding cast to Ptr<void> is refused" {
	const c = compileC(CAST + "const f: (n: int32) => int32 = add;\nsetOpt(1, f as Ptr<void>);\n");
	assert c.startsWith("ERROR"), c;
	assert c.contains("a closure carries an environment"), c;
}

test "C: a module-level function cast to Ptr<void> still compiles" {
	const c = compileC(CAST + "setOpt(1, add as Ptr<void>);\n");
	assert !c.startsWith("ERROR"), c;
}

const CONST_SLOTS_HEADER = "test/cFunctionPointer/constSlots.h";
const CONST_SLOTS = "typedef struct Pair { int a; int b; int c; int d; } Pair;\n"
	+ "typedef void (*PairSink)(void *, const Pair *);\n"
	+ "typedef void (*ByteSink)(void *, const unsigned char *, unsigned long);\n"
	+ "void runPairSink(PairSink f);\n"
	+ "void runByteSink(ByteSink f);\n";

function compileConstSlots(main: string): string {
	const t = createDefineTable();
	applyDefineSwitch(t, "-d:c");
	applyDefineSwitch(t, "-d:backend=c");
	setParserDefines(t);
	const entries: MapEntry[] = [{ entryPath: CONST_SLOTS_HEADER, entrySource: CONST_SLOTS }, { entryPath: MAIN, entrySource: main }];
	const out = compileProjectToC(entries, MAIN);
	resetParserDefines();
	return out;
}

const PAIR_IMPORT = "import { runPairSink, Pair } from \"./constSlots.h\";\n";
const BYTE_IMPORT = "import { runByteSink } from \"./constSlots.h\";\n";

test "C: a by-value struct parameter against a header const T* slot is refused, naming Readonly<Ptr<T>>" {
	const c = compileConstSlots(PAIR_IMPORT + "function sink(u: Ptr<void> | null, p: Pair): void {}\nrunPairSink(sink);\n");
	assert c.startsWith("ERROR"), c;
	assert c.contains("declare the parameter Readonly<Ptr<Pair>> | null and narrow it inside"), c;
	assert !c.contains("Readonly<Readonly"), c;
}

test "C: a by-value byte parameter against a header const uint8 pointer slot is refused, naming Readonly<Ptr<uint8>>" {
	const c = compileConstSlots(BYTE_IMPORT + "function sink(u: Ptr<void> | null, b: uint8, n: uint64): void {}\nrunByteSink(sink);\n");
	assert c.startsWith("ERROR"), c;
	assert c.contains("Readonly<Ptr<uint8>>"), c;
}

test "C: a Readonly<Ptr<T>> parameter fills a header const T* slot and is emitted const" {
	const c = compileConstSlots(PAIR_IMPORT + "function sink(u: Ptr<void> | null, p: Readonly<Ptr<Pair>> | null): void {}\nrunPairSink(sink);\n");
	assert !c.startsWith("ERROR"), c;
	assert c.contains("const Pair*"), c;
}

test "C: a Readonly<Ptr<uint8>> parameter fills a header const uint8 pointer slot and slices" {
	const c = compileConstSlots(BYTE_IMPORT + "function sink(u: Ptr<void> | null, p: Readonly<Ptr<uint8>> | null, n: uint64): void {\n"
		+ "\tif (p === null) return;\n\tlet total = 0;\n\tfor (const b of p[0..n]) { total += b; }\n}\nrunByteSink(sink);\n");
	assert !c.startsWith("ERROR"), c;
	assert c.contains("const uint8_t*"), c;
}

const PUSH = "import { Unary } from \"./sort.h\";\nfunction twice(n: int32): int32 { return n * 2; }\n";

test "C: a routine pushed onto an array of a header's function pointer stays a plain pointer" {
	const c = compileC(PUSH + "const xs: Unary[] = [];\nxs.push(twice);\nconsole.log(xs[0](5));\n");
	assert !c.startsWith("ERROR"), c;
	assert c.contains("msGenericArrayPush("), c;
	assert !c.contains("msClosure){ .fn = (void*)twice"), c;
}

test "C: a routine passed to a sink parameter of a header's function pointer stays a plain pointer" {
	const c = compileC(PUSH + "function put(sink f: Unary): int32 { return f(5); }\nfunction hold<T>(sink v: T): T { return v; }\nconsole.log(put(twice));\nconst g: Unary = hold<Unary>(twice);\nconsole.log(g(5));\n");
	assert !c.startsWith("ERROR"), c;
	assert !c.contains("msClosure){ .fn = (void*)twice"), c;
}
