import { compileProjectToC, MapEntry } from "../helpers";
import { setParserDefines, resetParserDefines } from "../../parser/context";
import { createDefineTable, applyDefineSwitch } from "../../compiler/defines";

const HEADER = "test/cFunctionPointer/sort.h";
const MAIN = "test/cFunctionPointer/main.ms";
const SORT = "typedef int (*Compare)(const void *, const void *);\n"
	+ "void sortAll(void *base, unsigned long count, Compare compare);\n"
	+ "void eachIndex(int count, void (*visit)(int));\n";

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
