import { option, step, executable, runArtifact, systemCommand, updateSourceFiles, path, Optimize, mscExe, LtoMode, Executable, Command, BuildNode } from "std/build";

const optimize = Optimize.ReleaseFast;

export const msc = executable({ entry: path("src/index.ms"), optimize, lto: LtoMode.None });
export default msc;

export const stage2 = executable({ entry: path("src/index.ms"), optimize, lto: LtoMode.None, compiler: msc });
export const stage3 = executable({ entry: path("src/index.ms"), optimize, lto: LtoMode.None, compiler: stage2 });

export const fixpoint = systemCommand(["cmp"]);
fixpoint.addArtifactArg(stage2);
fixpoint.addArtifactArg(stage3);
fixpoint.expectExitCode(0);

function withSubject(subject: Executable, argv: string[]): Command {
	const c = systemCommand(["env"]);
	c.addPrefixedArtifactArg("MSC=", subject);
	c.addArgs(argv);
	return c;
}

function checked(c: Command): Command {
	c.expectExitCode(0);
	for (const tree of [path("src"), path("std"), path("runtime")]) c.addFileInput(tree);
	return c;
}

export const test = checked(runArtifact(msc, ["test"]));
export const suite = checked(runArtifact(msc, ["test", "src/index.ms"]));

export const corpusRunner = executable({ entry: path("src/test/corpus/run.ms") });
export const corpus = withSubject(msc, []);
corpus.addArtifactArg(corpusRunner);

const guardShards = Number(option("guardShards", "how many guard runners split the guards between them") ?? "8");
const guardShard = (i: number): Command => {
	const c = withSubject(msc, [mscExe(), "run", "--target=raiser", "src/test/guard/run.ms"]);
	c.setEnvironmentVariable("GUARD_SHARD", `${i}/${guardShards}`);
	return c;
};
const shards: BuildNode[] = [];
for (let i = 0; i < guardShards; i++) shards.push(guardShard(i));
export const guard = step({ description: "every lifecycle guard", inputs: shards, make: (): void => {} });
export const fmt = runArtifact(msc, ["run", "src/test/fmt/run.ms"]);
export const lsp = withSubject(msc, []);
lsp.addArtifactArg(msc);
lsp.addArgs(["run", "--target=raiser", "src/test/lsp/run.ms"]);

const tables = systemCommand(["node", "tools/genStringCaseTables.mjs"]);
tables.addFileInput(path("tools/genStringCaseTables.mjs"));
export const stringCaseTables = updateSourceFiles();
stringCaseTables.addCopyFileToSource(tables.captureStdOut(), path("runtime/core/stringCaseTables.h"));

