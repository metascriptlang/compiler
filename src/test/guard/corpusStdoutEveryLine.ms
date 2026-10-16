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
const sandbox = root + "/out/guard/corpusStdoutEveryLine";
const programs = sandbox + "/src/test/corpus/programs";
removeAll(sandbox);
ensureDir(programs);

const windowsTimer = readFile(root + "/src/test/corpus/wintime.c");
requireCondition(windowsTimer.ok, "cannot read the corpus runner's Windows timer");
if (windowsTimer.ok) {
	writeRequired(sandbox + "/src/test/corpus/wintime.c", windowsTimer.value);
}
const body = "for (let i: int32 = 1; i <= 3; i += 1) {\n" +
	"\tconsole.log(\"line \" + i.toString());\n}\n";
const entry = programs + "/threeLines.ms";

env.set("MSC", compiler);
env.set("MSCORPUS_ONLY", "threeLines");
env.set("MSCORPUS_FILTER", "");
env.set("MSCORPUS_LANES", "c");
env.set("MSCORPUS_BUILD_JOBS", "1");
env.set("MSCORPUS_JOBS", "1");
env.set("MSCORPUS_SAN", "0");
env.set("MSCORPUS_RAISER", "0");
const runner = root + "/src/test/corpus/run.ms";

writeRequired(entry, "// @stdout: line 1\n// @stdout: line 2\n// @stdout: line 3\n" + body);
const positive = execFileResult(compiler, ["run", runner], sandbox);
const positiveLog = positive.output + positive.errorOutput;
const positiveRan = positive.started && positive.pipeOk && positive.signal == 0;
requireCondition(positiveRan && positive.exitCode == 0, positiveLog);
requireCondition(
	positiveLog.contains("✓ threeLines [c]"),
	"the program was not executed\n" + positiveLog,
);

writeRequired(entry, "// @stdout: line 7\n// @stdout: line 2\n// @stdout: line 9\n" + body);
const negative = execFileResult(compiler, ["run", runner], sandbox);
const negativeLog = negative.output + negative.errorOutput;
const negativeRan = negative.started && negative.pipeOk && negative.signal == 0;
requireCondition(
	negativeRan && negative.exitCode != 0,
	"a wrong first @stdout line must fail\n" + negativeLog,
);
requireCondition(
	negativeLog.contains("FAIL threeLines [c]"),
	"the failing program was not named\n" + negativeLog,
);
requireCondition(
	negativeLog.contains("'line 7'"),
	"the missing first line was not named\n" + negativeLog,
);
requireCondition(
	negativeLog.contains("'line 9'"),
	"the missing last line was not named\n" + negativeLog,
);
requireCondition(
	!negativeLog.contains("'line 2'"),
	"a present line was named as missing\n" + negativeLog,
);
removeAll(sandbox);
console.log("GUARD-OK");
