import { option, step, executable, runArtifact, systemCommand, updateSourceFiles, path, Optimize, mscExe, LtoMode, Command, BuildNode } from "std/build";

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
