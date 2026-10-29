// A header's size_t slots take the header's own size_t on every target with no cast: a size_t*
// parameter written through a variable, and a module function with a size_t parameter handed to
// a header function-pointer parameter. Sibling of headerScalarRefusal, whose harness this copies.

import { compileProjectToC, MapEntry } from "../helpers";
import { setParserDefines, resetParserDefines } from "../../parser/context";
import { createDefineTable, applyDefineSwitch } from "../../compiler/defines";

const HEADER = "test/headerSizeTSlots/cb.h";
const MAIN = "test/headerSizeTSlots/main.ms";
const CB = "typedef unsigned long size_t;\ntypedef unsigned char uint8_t;\n"
	+ "size_t fill(size_t *written);\nvoid setCb(void (*cb)(void *, const uint8_t *, size_t));\n";
const USE = "import { fill, setCb, size_t } from \"./cb.h\";\n"
	+ "function onData(u: Ptr<void> | null, bytes: Readonly<Ptr<uint8>> | null, n: size_t): void {\n\tconsole.log(`${n}`);\n}\n"
	+ "setCb(onData);\nlet written: size_t = 0;\nfill(written);\n";

function compileOn(os: string, cpu: string): string {
	const t = createDefineTable();
	applyDefineSwitch(t, "-d:c");
	applyDefineSwitch(t, "-d:backend=c");
	applyDefineSwitch(t, `-d:os=${os}`);
	applyDefineSwitch(t, `-d:cpu=${cpu}`);
	setParserDefines(t);
	const entries: MapEntry[] = [{ entryPath: HEADER, entrySource: CB }, { entryPath: MAIN, entrySource: USE }];
	const out = compileProjectToC(entries, MAIN);
	resetParserDefines();
	return out;
}

test "C: a size_t* argument and a size_t callback parameter compile without a cast on wasm32 and x86_64" {
	for (const [os, cpu] of [["emcc", "wasm32"], ["linux", "x86_64"]]) {
		const c = compileOn(os, cpu);
		assert !c.startsWith("ERROR"), c;
		assert c.contains("size_t"), c;
	}
}
