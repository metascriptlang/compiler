import { compileProjectToCWithStd, MapEntry } from "../helpers";

const HEADER = "test/copiedBodyHeader/probe.h";
const LIB_PATH = "test/copiedBodyHeader/lib.ms";
const MID_PATH = "test/copiedBodyHeader/mid.ms";
const MAIN_PATH = "test/copiedBodyHeader/main.ms";

const COMPTIME = `@comptime
export function seven(): int32 { return 7; }
export const SEVEN: int32 = seven();
`;

function lib(comptimeInit: boolean, generic: boolean): string {
	const head = `@include("${HEADER}");\nextern function portableRead(x: int32): int32;\n`;
	const fn = generic
		? "@inline\nexport function read<T>(x: T): int32 { return portableRead(1); }\n"
		: "@inline\nexport function read(x: int32): int32 { return portableRead(x); }\n";
	return head + (comptimeInit ? COMPTIME : "") + fn;
}

function consumerC(entries: MapEntry[], entryPath: string, stem: string): string {
	const cCode = compileProjectToCWithStd(entries, entryPath);
	if (cCode.startsWith("ERROR")) return cCode;
	const units = cCode.split("#include <stdint.h>\n");
	for (const unit of units) {
		if (unit.contains(`Z${stem}Oms__Init000(void) {`)) return unit;
	}
	return "";
}

function twoModules(comptimeInit: boolean, generic: boolean): string {
	const call = generic ? "read<int32>(40)" : "read(40)";
	return consumerC([
		{ entryPath: LIB_PATH, entrySource: lib(comptimeInit, generic) },
		{ entryPath: MAIN_PATH, entrySource: `import { read } from "./lib";\nconsole.log(${call});\n` },
	], MAIN_PATH, "main");
}

test "a copied @inline body brings the header of the extern it calls" {
	const main = twoModules(false, false);
	assert main != "" && !main.startsWith("ERROR"), main;
	assert main.contains("portableRead(x)");
	assert main.contains(`#include "${HEADER}"`);
}

test "a provider with an @comptime initializer still hands its header to the copy" {
	const main = twoModules(true, false);
	assert main != "" && !main.startsWith("ERROR"), main;
	assert main.contains("portableRead(x)");
	assert main.contains(`#include "${HEADER}"`);
}

test "a copied generic @inline instance brings the header beside an @comptime initializer" {
	const main = twoModules(true, true);
	assert main != "" && !main.startsWith("ERROR"), main;
	assert main.contains("portableRead(");
	assert main.contains(`#include "${HEADER}"`);
}

test "a copy made through a middle module brings the provider header" {
	const mid = `import { read } from "./lib";\n@inline\nexport function viaMid(x: int32): int32 { return read(x); }\n`;
	const main = consumerC([
		{ entryPath: LIB_PATH, entrySource: lib(true, false) },
		{ entryPath: MID_PATH, entrySource: mid },
		{ entryPath: MAIN_PATH, entrySource: `import { viaMid } from "./mid";\nconsole.log(viaMid(40));\n` },
	], MAIN_PATH, "main");
	assert main != "" && !main.startsWith("ERROR"), main;
	assert main.contains("portableRead(x)");
	assert main.contains(`#include "${HEADER}"`);
}
