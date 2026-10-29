// E2E C: an imported C variable is a module global for the checker (it has a key another module can name)
// and an extern prototype for codegen: a reader in another module names the C symbol and declares nothing of its own.

import { compileProjectToC, MapEntry } from "../helpers";

function emitReader(declaration: string): string {
	const entries: MapEntry[] = [
		{ entryPath: "test/lib.ms", entrySource: `@include("stdint.h");\n${declaration}\nexport function read(): int32 { return limit as int32; }\n` },
		{ entryPath: "test/main.ms", entrySource: `import { read } from "./lib";\nconst n = read();\n` },
	];
	return compileProjectToC(entries, "test/main.ms");
}

test "E2E C: an extern const read from a function body keeps its C name" {
	const c = emitReader("extern const limit: int32 from \"INT32_MAX\";");
	assert c.contains("INT32_MAX");
	assert !c.contains("extern int32_t INT32_MAX"), c;
}

test "E2E C: an extern let read from a function body keeps its C name" {
	const c = emitReader("extern let limit: int32 from \"INT32_MAX\";");
	assert c.contains("INT32_MAX");
	assert !c.contains("extern int32_t INT32_MAX"), c;
}
