import { cwd, env, execFileResult, exit } from "std/process";
import { ensureDir, readFile, removeAll, writeFile } from "std/fs";

function requireCondition(ok: boolean, detail: string): void {
	if (!ok) {
		console.log("GUARD-FAIL " + detail);
		exit(1);
	}
}

function writeRequired(path: string, source: string): void {
	const result = writeFile(path, source);
	requireCondition(result.ok, "cannot write corpus fixture " + path);
}

const root = cwd().replaceAll("\\", "/");
const selectedCompiler = env.get("MSC");
const compiler = selectedCompiler != "" ? selectedCompiler : root + "/msc";
const sandbox = root + "/out/guard/corpusEntryNames";
const programs = sandbox + "/src/test/corpus/programs";
removeAll(sandbox);
ensureDir(programs + "/semanticModule");

const windowsTimer = readFile(root + "/src/test/corpus/wintime.c");
requireCondition(windowsTimer.ok, "cannot read the corpus runner's Windows timer");
if (windowsTimer.ok) {
	writeRequired(sandbox + "/src/test/corpus/wintime.c", windowsTimer.value);
}
writeRequired(programs + "/010-legacy.ms", "// @stdout: legacy 10\nfunction twice(n: int32): int32 { return n * 2; }\nconsole.log(\"legacy \" + twice(5).toString());\n");
const semanticBody = "let sum: int32 = 0;\nfor (let i: int32 = 0; i < 4; i += 1) { sum += i; }\nconsole.log(\"semantic \" + sum.toString());\n";
writeRequired(programs + "/semanticEntry.ms", "// @stdout: semantic 6\n" + semanticBody);
writeRequired(programs + "/semanticModule/value.ms", "export function value(): int32 { return 21; }\n");
writeRequired(programs + "/semanticModule/main.ms", "// @stdout: module 42\nimport { value } from \"./value\";\nconsole.log(\"module \" + (value() * 2).toString());\n");

env.set("MSC", compiler);
env.set("MSCORPUS_ONLY", "010-legacy,semanticEntry,semanticModule");
env.set("MSCORPUS_FILTER", "");
env.set("MSCORPUS_LANES", "c");
env.set("MSCORPUS_BUILD_JOBS", "1");
env.set("MSCORPUS_JOBS", "1");
env.set("MSCORPUS_SAN", "0");
env.set("MSCORPUS_RAISER", "0");
const runner = root + "/src/test/corpus/run.ms";
const positive = execFileResult(compiler, ["run", runner], sandbox);
const positiveLog = positive.output + positive.errorOutput;
requireCondition(positive.started && positive.pipeOk && positive.exitCode == 0 && positive.signal == 0, positiveLog);
for (const name of ["010-legacy", "semanticEntry", "semanticModule"]) {
	requireCondition(positiveLog.contains("✓ " + name + " [c]"), "entry was not executed: " + name + "\n" + positiveLog);
}

writeRequired(programs + "/semanticEntry.ms", "// @stdout: semantic 7\n" + semanticBody);
env.set("MSCORPUS_ONLY", "semanticEntry");
const negative = execFileResult(compiler, ["run", runner], sandbox);
const negativeLog = negative.output + negative.errorOutput;
requireCondition(negative.started && negative.pipeOk && negative.exitCode != 0 && negative.signal == 0, "wrong expected output must fail\n" + negativeLog);
requireCondition(negativeLog.contains("FAIL semanticEntry [c]"), "the failing semantic entry was not named\n" + negativeLog);
requireCondition(negativeLog.contains("stdout"), "the output contract was not enforced\n" + negativeLog);
removeAll(sandbox);
console.log("GUARD-OK");
