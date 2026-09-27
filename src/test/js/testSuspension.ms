import { compileTestBuildToJS } from "../helpers";
import { writeFile, ensureDir, removeAll } from "std/fs";
import { cwd, execFileCapture } from "std/process";

test "JavaScript accepts suspension in direct and nested generated test bodies" {
	const root = cwd() + "/out/testSuspension-" + performance.now().toString();
	ensureDir(root);
	defer removeAll(root);
	const cases = [
		"await sleepAsync(1); assert 2 + 3 == 5;",
		"if (true) { await sleepAsync(1); } assert 7 - 2 == 5;",
	];
	for (let i = 0; i < cases.length; i += 1) {
		const result = compileTestBuildToJS(`import { sleepAsync } from "std/core/promise"; test "suspended" { ${cases[i]} }`);
		assert result.ok, result.ok ? "" : result.error;
		const path = root + "/wrapper" + i.toString() + ".mjs";
		const written = writeFile(path, result.value);
		assert written.ok, path;
		const parsed = execFileCapture("node", ["--check", path]);
		assert parsed.ok, parsed.ok ? "" : parsed.error.errorOutput;
	}
}
