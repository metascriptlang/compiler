// E2E JS: an extern const read from a function body keeps its own name instead of becoming a mangled module global.

import { compileProjectToJS, MapEntry } from "../helpers";

test "E2E JS: an extern const read from a function body keeps its own name" {
	const lib = `@import("node:process", { stdout });\nextern const stdout: { write: (s: string) => void };\nexport function put(s: string): void { stdout.write(s); }\n`;
	const entries: MapEntry[] = [
		{ entryPath: "test/lib.ms", entrySource: lib },
		{ entryPath: "test/main.ms", entrySource: `import { put } from "./lib";\nput("x");\n` },
	];
	const js = compileProjectToJS(entries, "test/main.ms");
	assert js.contains("stdout.write("), js;
	assert !js.contains("_stdout"), js;
}
