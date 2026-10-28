import { compileToC } from "../helpers";

const AUTHOR_ERROR = "class Error { code: int32 = 7; label: string = \"mine\"; }\nasync function bare(i: int32): Promise<int32> { if (i >= 0) throw \"x\"; return i; }\n";

function caughtBindings(src: string): string[] {
	const c = compileToC(src);
	if (!c.ok) return ["compile failed: " + c.error];
	const found: string[] = [];
	for (const line of c.value.split("\n")) {
		if (line.contains(" dollare__") && line.contains("msCurrException")) found.push(line.trim());
	}
	return found;
}

function authorTyped(bindings: string[]): string {
	if (bindings.length == 0) return "no lowered catch binding emitted";
	for (const b of bindings) {
		if (b.contains("e2eOms*")) return b;
	}
	return "";
}

test "E2E C: a lowered try-await catch in a function binds std's Error beside an author's Error" {
	const verdict = authorTyped(caughtBindings(AUTHOR_ERROR + "function run(): int32 { return try await bare(1) catch -1; }\nconsole.log(run());"));
	assert verdict == "", verdict;
}

test "E2E C: a lowered try-await catch at module top level binds std's Error beside an author's Error" {
	const verdict = authorTyped(caughtBindings(AUTHOR_ERROR + "const k = try await bare(1) catch -1;\nconsole.log(k);"));
	assert verdict == "", verdict;
}
