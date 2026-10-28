import { refusedOnEveryBackend, compileProjectToC } from "../helpers";

const WIDE = "enum H { X0, X1, X2, X3, X4, X5, X6, X7, X8, X9, X10, X11, X12, X13, X14, X15, X16, X17, X18, X19, X20, X21, X22, X23, X24, X25, X26, X27, X28, X29, X30, X31, X32, X33, X34, X35, X36, X37, X38, X39, X40, X41, X42, X43, X44, X45, X46, X47, X48, X49, X50, X51, X52, X53, X54, X55, X56, X57, X58, X59, X60, X61, X62, X63, X64, X65, X66, X67, X68, X69, X70, X71, X72, X73, X74, X75, X76, X77, X78, X79, X80, X81, X82, X83, X84, X85, X86, X87, X88, X89, X90, X91, X92, X93, X94, X95, X96, X97, X98, X99 }\n";
const PRELUDE = "let calls = 0;\nconst b = (0 as BitSet<H>).incl(H.X70);\nfunction mk(): BitSet<H> { calls += 1; return (0 as BitSet<H>).incl(H.X1).incl(H.X70); }\n";
const NEEDLE = "BitSet operation over 64 members";

test "bitSetLower: a wide-set operand in a switch case label is refused where it cannot be hoisted" {
	const source = WIDE + PRELUDE + "switch (1) { case mk().intersection(b).size(): console.log(\"hit\", calls); break; default: console.log(\"miss\", calls); }";
	const verdict = refusedOnEveryBackend(source, NEEDLE);
	assert verdict == "", verdict;
}

test "bitSetLower: a wide-set union in a switch case label is refused the same way" {
	const source = WIDE + PRELUDE + "switch (2) { case mk().union(b).size(): console.log(\"hit\", calls); break; default: console.log(\"miss\", calls); }";
	const verdict = refusedOnEveryBackend(source, NEEDLE);
	assert verdict == "", verdict;
}

test "bitSetLower: a wide-set operand refused in an importing module stops a multi-module C build at the transform" {
	const lib = "export " + WIDE + "export function mk(): BitSet<H> { return (0 as BitSet<H>).incl(H.X1).incl(H.X70); }\n";
	const main = "import { H, mk } from \"./wide\";\nconst b = (0 as BitSet<H>).incl(H.X70);\nswitch (1) { case mk().intersection(b).size(): console.log(\"hit\"); break; default: console.log(\"miss\"); }";
	const c = compileProjectToC([{ entryPath: "src/wide.ms", entrySource: lib }, { entryPath: "src/main.ms", entrySource: main }], "src/main.ms");
	assert c.startsWith("ERROR: transform [") && c.includes(NEEDLE), c.slice(0, 300);
}
