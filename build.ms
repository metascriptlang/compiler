import { option, step, executable, runArtifact, systemCommand, updateSourceFiles, writeFiles, path, Optimize, mscExe, LtoMode, Command, BuildNode, Arg } from "std/build";

const optimize = Optimize.ReleaseFast;

export const msc = executable({ entry: path("src/index.ms"), optimize, lto: LtoMode.None });
export default msc;

export const stage2 = executable({ entry: path("src/index.ms"), optimize, lto: LtoMode.None, compiler: msc });
export const stage3 = executable({ entry: path("src/index.ms"), optimize, lto: LtoMode.None, compiler: stage2 });

export const fixpoint = systemCommand(["cmp", stage2, stage3], { expectExitCode: 0 });

const sources = [path("src"), path("std"), path("runtime")];

export const test = runArtifact(msc, ["test"], { expectExitCode: 0, inputs: sources });
export const suite = runArtifact(msc, ["test", "src/index.ms"], { expectExitCode: 0, inputs: sources });

function tier(entry: string, args: string[] = []): Command {
	return runArtifact(msc, ["test", entry, "--tests-in-dir"].concat(args), {
		env: { MSC: msc },
		expectExitCode: 0,
		inputs: sources,
		description: ["tests", entry].concat(args).join(" "),
	});
}
const tiers: BuildNode[] = ["js", "handoff", "checker3pass", "lang", "fmt", "crypto"].map((name: string): BuildNode => tier(`src/test/${name}/index.ms`));
tiers.push(tier("src/test/helpers.ms"));
for (let i = 0; i < 3; i++) tiers.push(tier("src/test/c/index.ms", [`--tests-shard=${i}/3`]));
export const tests = step({ description: "every tier index", inputs: tiers });

export const corpusRunner = executable({ entry: path("src/test/corpus/run.ms") });
export const corpus = runArtifact(corpusRunner, [], { env: { MSC: msc } });

const guardShards = option("guardShards", "how many guard runners split the guards between them", 8);
const shards: BuildNode[] = [];
for (let i = 0; i < guardShards; i++) {
	shards.push(systemCommand([mscExe(), "run", "--target=raiser", "src/test/guard/run.ms"], { env: { MSC: msc, GUARD_SHARD: `${i}/${guardShards}` } }));
}
export const guard = step({ description: "every lifecycle guard", inputs: shards });
export const fmt = runArtifact(msc, ["run", "src/test/fmt/run.ms"]);
export const lsp = runArtifact(msc, ["run", "--target=raiser", "src/test/lsp/run.ms"], { env: { MSC: msc } });

const tables = systemCommand(["node", "tools/genStringCaseTables.mjs"], { inputs: [path("tools/genStringCaseTables.mjs")] });
export const stringCaseTables = updateSourceFiles();
stringCaseTables.addCopyFileToSource(tables.captureStdOut(), path("runtime/core/stringCaseTables.h"));

const subject = option("subject", "the compiler the gate lanes test; the graph's own msc when unset", "");
const candidate: Arg = subject == "" ? msc : path(subject);
const withTrailer = 't0=$SECONDS; "$@" 2>&1; rc=$?; printf "\\nSECS=%d\\nRC=%d\\nEND\\n" $((SECONDS - t0)) $rc';

const selected = option("lanes", "the gate lanes to run, comma-separated; every lane when unset", "");
export const lanes = writeFiles();
function lane(name: string, command: Arg[], env: Record<string, Arg> = {}): void {
	if (selected != "" && !selected.split(",").includes(name.split(".")[0])) return;
	const argv: Arg[] = ["bash", "-c", withTrailer, name, "env", "-u", "FORCE_COLOR", "NO_COLOR=1"];
	const log = systemCommand(argv.concat(command), { env, inputs: sources, description: `lane ${name}` }).captureStdOut();
	lanes.addCopyFile(log, `${name}.log`);
}

const raiser: Arg[] = [candidate, "run", "--target=raiser"];
const under: Record<string, Arg> = { MSC: candidate };
lane("suite", [candidate, "test", "--time", "src/index.ms"]);
for (const name of ["js", "handoff", "checker3pass", "lang", "fmt", "crypto"]) lane(`tests.${name}`, [candidate, "test", "--time", `src/test/${name}/index.ms`, "--tests-in-dir"], under);
lane("tests.helpers", [candidate, "test", "--time", "src/test/helpers.ms", "--tests-in-dir"], under);
for (let i = 0; i < 3; i++) lane(`tests.c${i}`, [candidate, "test", "--time", "src/test/c/index.ms", "--tests-in-dir", `--tests-shard=${i}/3`], under);
for (let i = 0; i < guardShards; i++) lane(`guard.${i}`, raiser.concat(["src/test/guard/run.ms"]), { MSC: candidate, GUARD_SHARD: `${i}/${guardShards}` });
const hcrShards = option("hcrShards", "how many hcr runners split the hot-reload tests between them", 4);
for (let i = 0; i < hcrShards; i++) lane(`hcr.${i}`, raiser.concat(["src/test/hcr/run.ms"]), { MSC: candidate, HCR_SHARD: `${i}/${hcrShards}` });
lane("fmt", [candidate, "run", "src/test/fmt/run.ms"]);
lane("lsp", raiser.concat(["src/test/lsp/run.ms"]), under);
lane("cache", raiser.concat(["src/test/cache/run.ms", candidate]));
for (const name of ["nativeBuildBoundary", "projectConfigCommands", "preludePackKey"]) lane(`boundary.${name}`, raiser.concat([`src/test/${name}.ms`, candidate]));
lane("corpus", [corpusRunner], { MSC: candidate, MSCORPUS_RAISER: "1" });
lane("san", [corpusRunner], { MSC: candidate, MSCORPUS_SAN: "1" });

const gateTool = executable({ entry: path("tools/gate.ms"), optimize });
export const gate = systemCommand([gateTool, lanes.getDirectory(), path("src/test/known-red.json")], { expectExitCode: 0, description: "the verdict over the lane logs" });
