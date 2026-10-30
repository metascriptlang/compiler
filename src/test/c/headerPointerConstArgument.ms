import { compileProjectToC, MapEntry } from "../helpers";
import { setParserDefines, resetParserDefines } from "../../parser/context";
import { createDefineTable, applyDefineSwitch } from "../../compiler/defines";

const HEADER = "test/headerPointerConstArgument/counter.h";
const MAIN = "test/headerPointerConstArgument/main.ms";
const COUNTER = "typedef struct { int hits; double total; } Tally;\n"
	+ "typedef struct { Tally tally; int id; } Slot;\n"
	+ "void tallyAdd(Tally *tally, double value);\n"
	+ "double tallyMean(const Tally *tally);\n";

function compileC(main: string): string {
	const t = createDefineTable();
	applyDefineSwitch(t, "-d:c");
	applyDefineSwitch(t, "-d:backend=c");
	setParserDefines(t);
	const entries: MapEntry[] = [{ entryPath: HEADER, entrySource: COUNTER }, { entryPath: MAIN, entrySource: main }];
	const out = compileProjectToC(entries, MAIN);
	resetParserDefines();
	return out;
}

const IMPORT = "import { Tally, Slot, tallyAdd, tallyMean } from \"./counter.h\";\n";

test "C: a const struct into a header's non-const pointer parameter is refused" {
	const c = compileC(IMPORT + "const tally: Tally = { hits: 0, total: 0 };\ntallyAdd(tally, 3);\n");
	assert c.startsWith("ERROR"), c;
	assert c.contains("cannot pass 'tally' to a non-const C pointer parameter — 'tally' is const (use 'let')"), c;
}

test "C: a const struct into a header's const pointer parameter is accepted" {
	const c = compileC(IMPORT + "const tally: Tally = { hits: 0, total: 0 };\nconsole.log(tallyMean(tally));\n");
	assert !c.startsWith("ERROR"), c;
}

test "C: a let struct into a header's non-const pointer parameter is accepted" {
	const c = compileC(IMPORT + "let tally: Tally = { hits: 0, total: 0 };\ntallyAdd(tally, 3);\n");
	assert !c.startsWith("ERROR"), c;
}

test "C: a field of a const struct into a header's non-const pointer parameter is refused" {
	const c = compileC(IMPORT + "const slot: Slot = { tally: { hits: 0, total: 0 }, id: 1 };\ntallyAdd(slot.tally, 3);\n");
	assert c.startsWith("ERROR"), c;
	assert c.contains("cannot pass 'slot.tally' to a non-const C pointer parameter — 'slot' is const (use 'let')"), c;
}

test "C: a value parameter into a header's non-const pointer parameter is refused" {
	const c = compileC(IMPORT + "function bump(tally: Tally): void { tallyAdd(tally, 1); }\nlet t: Tally = { hits: 0, total: 0 };\nbump(t);\n");
	assert c.startsWith("ERROR"), c;
	assert c.contains("cannot mutate value-type parameter 'tally'"), c;
}
