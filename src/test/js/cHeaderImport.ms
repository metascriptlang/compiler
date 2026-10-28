import { parseAsBuildOf } from "../../parser/context";
import { compileProjectToJSWithStd, MapEntry } from "../helpers";

function emitWith(header: string, src: string): string {
	const entries: MapEntry[] = [
		{ entryPath: "test/bridge.h", entrySource: header },
		{ entryPath: "test/cHeaderImport.ms", entrySource: src },
	];
	return parseAsBuildOf("js", (): string => compileProjectToJSWithStd(entries, "test/cHeaderImport.ms"));
}

test "E2E JS: a call to a function imported from a C header is refused at the import, naming the header" {
	const js = emitWith("int twice(int value);", "import { twice } from \"./bridge.h\";\nconsole.log(twice(21));\n");
	assert js.contains("'./bridge.h' is a C header and has no JS implementation");
}

test "E2E JS: a constant imported from a C header is refused the same way" {
	const js = emitWith("static const int ANSWER = 42;", "import { ANSWER } from \"./bridge.h\";\nconsole.log(ANSWER);\n");
	assert js.contains("'./bridge.h' is a C header and has no JS implementation");
}

test "E2E JS: the same import inside when (c) builds" {
	const js = emitWith("int twice(int value);", "when (c) { import { twice } from \"./bridge.h\"; console.log(twice(21)); }\nconsole.log(1);\n");
	assert !js.contains("C header");
}
