import { option, step, executable, runArtifact, systemCommand, updateSourceFiles, writeFiles, path, glob, Optimize, mscExe, LtoMode, Command, BuildNode, Arg, LazyPath } from "std/build";

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
stringCaseTables.addCopyFileToSource(tables.captureStdOut(), path("std/core/string/caseTables.ms"));

const subject = option("subject", "the compiler the gate lanes test; the graph's own msc when unset", "");
const candidate: Arg = subject == "" ? msc : path(subject);
const laneLimit = option("laneLimit", "seconds a gate lane may run before its process tree is killed", 5400);
const withTrailer = 'limit=$1; shift; t0=$SECONDS; set -m; "$@" 2>&1 & lane=$!; (sleep "$limit"; kill -KILL -- "-$lane") >/dev/null 2>&1 & watch=$!; set +m; wait "$lane"; rc=$?; kill -KILL -- "-$watch" 2>/dev/null || printf "\\nTIMEOUT after %ss, process tree killed\\n" "$limit"; printf "\\nSECS=%d\\nRC=%d\\nEND\\n" $((SECONDS - t0)) $rc';

const selected = option("lanes", "the gate lanes to run, comma-separated; every lane when unset", "");
export const lanes = writeFiles();
const noColourVariable = ["suite", "tests", "fmt", "cache", "crypto", "tools"];
function wanted(name: string): boolean {
	return selected == "" || selected.split(",").includes(name.split(".")[0]);
}
function bounded(lane: string, description: string, command: Arg[], env: Record<string, Arg>, inputs: LazyPath[], limit: number = laneLimit): Command {
	const colour: Arg[] = noColourVariable.includes(lane) ? ["-u", "NO_COLOR"] : ["NO_COLOR=1"];
	const argv: Arg[] = ["bash", "-c", withTrailer, lane, `${limit}`, "env", "-u", "FORCE_COLOR"];
	return systemCommand(argv.concat(colour).concat(command), { env, inputs, description, timeout: (limit + 60) * 1000 });
}
function laneNode(name: string, command: Arg[], env: Record<string, Arg> = {}, inputs: LazyPath[] = sources): Command {
	const node = bounded(name.split(".")[0], `lane ${name}`, command, env, inputs);
	lanes.addCopyFile(node.captureStdOut(), `${name}.log`);
	return node;
}
function lane(name: string, command: Arg[], env: Record<string, Arg> = {}, inputs: LazyPath[] = sources): void {
	if (wanted(name)) laneNode(name, command, env, inputs);
}

const raiser: Arg[] = [candidate, "run", "--target=raiser"];
const under: Record<string, Arg> = { MSC: candidate };
lane("suite", [mscExe(), "test", "--time", "src/index.ms"], { MSC: mscExe() });
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
const afterSanWroteTheThreadedList = wanted("san") ? [laneNode("san", [corpusRunner], { MSC: candidate, MSCORPUS_SAN: "1" }).captureStdOut()] : [];
lane("tsan", [corpusRunner], { MSC: candidate, MSCORPUS_TSAN: "1" }, sources.concat(afterSanWroteTheThreadedList));
lane("crypto", ["bash", "src/test/crypto/suite.sh"], under);

const rerun = option("rerun", "the new reds a gate runs again, as <lane>=<subject>,<subject>;<lane>=<subject>", "");
const rerunCount = option("rerunCount", "how many times each of them runs, one after another", 3);
export const reruns = updateSourceFiles();
const eachFile = 'r=0; for file in "${@:2}"; do "$1" test --time "$file" --tests-in-dir || r=1; done; exit $r';
const eachHcrTest = 'r=0; for name in "${@:2}"; do HCR_ONLY=$name "$1" run --target=raiser src/test/hcr/run.ms || r=1; done; exit $r';
const keepingTheSanLanesThreadedList = 'list=out/corpus/threaded.txt; [ ! -f $list ] || cp -p $list $list.lane; "$@"; r=$?; [ ! -f $list.lane ] || mv -f $list.lane $list; exit $r';
function rerunCommand(lane: string, subjects: string[]): Arg[] {
	const perSubject: Arg[] = ["bash", "-c", lane == "hcr" ? eachHcrTest : eachFile, lane, lane == "suite" ? mscExe() : candidate];
	for (const subject of subjects) perSubject.push(subject);
	if (lane == "tests" || lane == "suite" || lane == "hcr") return perSubject;
	if (lane == "guard" || lane == "lsp") return raiser.concat([`src/test/${lane}/run.ms`]);
	if (lane == "corpus" || lane == "tsan") return [corpusRunner];
	if (lane == "san") return ["bash", "-c", keepingTheSanLanesThreadedList, lane, corpusRunner];
	throw new Error(`rerun: '${lane}' is not a lane whose reds run again (corpus, san, tsan, guard, hcr, lsp, tests, suite)`);
}
function rerunEnv(lane: string, subjects: string[], run: number): Record<string, Arg> {
	const env: Record<string, Arg> = { MSC: lane == "suite" ? mscExe() : candidate, GATE_RERUN: `${run}` };
	if (lane == "guard") env.set("GUARD_ONLY", subjects.join(","));
	if (lane != "corpus" && lane != "san" && lane != "tsan") return env;
	env.set("MSCORPUS_ONLY", subjects.join(","));
	env.set("MSCORPUS_CELL_TIMEOUT_MS", "120000");
	env.set(lane == "corpus" ? "MSCORPUS_RAISER" : lane == "san" ? "MSCORPUS_SAN" : "MSCORPUS_TSAN", "1");
	return env;
}
const rerunBase = option("rerunBase", "the commit of main that runs the same reruns, in a checkout of it at out/gate-main", "");
const inMainsCheckout = 'base=$1; builder=$2; shift 2; d=out/gate-main; if [ ! -e $d/.git ] || [ "$(git -C $d rev-parse HEAD)" != "$base" ]; then git worktree remove --force $d 2>/dev/null; rm -rf $d; git worktree prune; git worktree add -q -f --detach $d "$base" && mkdir -p $d/vendor && (cd vendor && tar cf - --exclude=.git .) | (cd $d/vendor && tar xf -) || exit 1; fi; cp -p "$builder" "$d/${builder##*/}" && rm -rf $d/out/reruns && cd $d && exec "./${builder##*/}" build "$@" reruns';
const rerunSpecs = rerun.split(";").filter((s: string): boolean => s != "");
if (rerunSpecs.length > 0 && rerunBase != "") {
	const sameReruns: Arg[] = ["bash", "-c", inMainsCheckout, "main", rerunBase, mscExe(), "--colors=off", `-Drerun=${rerun}`, `-DrerunCount=${rerunCount}`, `-DlaneLimit=${laneLimit}`];
	const main = bounded("main", "rerun on main", sameReruns, {}, [], 1800 + laneLimit * rerunCount * rerunSpecs.length);
	main.hasSideEffects = true;
	reruns.addCopyFileToSource(main.captureStdOut(), path("out/reruns/main.log"));
}
let earlierRun: LazyPath[] = [];
for (const spec of rerunSpecs) {
	const lane = spec.split("=")[0];
	const subjects = spec.substring(lane.length + 1).split(",").filter((s: string): boolean => s != "");
	if (subjects.length == 0) throw new Error(`rerun: '${spec}' names no subject after <lane>=`);
	for (let run = 1; run <= rerunCount; run++) {
		const node = bounded(lane, `rerun ${lane} ${run}`, rerunCommand(lane, subjects), rerunEnv(lane, subjects, run), sources.concat(earlierRun));
		earlierRun = [node.captureStdOut()];
		reruns.addCopyFileToSource(earlierRun[0], path(`out/reruns/${lane}.${run}.log`));
	}
}

const namedTest = 'name=$1; shift; out=$("$@" 2>&1); rc=$?; printf "%s\\n" "$out"; [ $rc -eq 0 ] || { printf "FAIL solana %s: exit %d\\n" "$name" $rc; exit 1; }; esc=$(printf "\\033"); sed "s/$esc\\[[0-9;]*m//g" <<<"$out" | grep -Eq "^ *Test Files +[0-9]" || { printf "FAIL solana %s: no test result\\n" "$name"; exit 1; }';
function solanaTest(entry: string, flags: string[]): void {
	const name = [entry].concat(flags).join(" ");
	const command: Arg[] = ["bash", "-c", namedTest, "solana", name, candidate, "test", entry];
	for (const flag of flags) command.push(flag);
	lane(`solana.${name.split("/").join("_").split(" ").join("_")}`, command);
}
const solanaBoth = ["accountCodecTest.ms", "memoryTest.ms", "simulatorContextTest.ms", "simulatorSeedsTest.ms", "simulatorMetasTest.ms", "simulatorLogTest.ms", "simulatorHostTest.ms"];
const solanaNative = ["test.ms", "hostTest.ms", "token.ms", "index.ms", "vrf.ms", "idlTest.ms", "simulatorProgramsTest.ms", "simulatorTokenTest.ms", "simulatorInvokeTest.ms"];
for (const file of solanaNative.concat(solanaBoth)) solanaTest(`std/solana/${file}`, []);
for (const entry of ["examples/escrow/program.ms", "examples/escrow/idl.cms", "examples/anchorBench/helloworld/program.ms"]) solanaTest(entry, []);
for (const file of solanaBoth.concat(["memoryMachineTest.jms", "kernelTest.jms"])) solanaTest(`std/solana/${file}`, ["--target=js"]);

const checked = 'name=$1; shift; "$@"; rc=$?; [ $rc -eq 0 ] || printf "FAIL solana %s: exit %d\\n" "$name" $rc; exit $rc';
const afterBuilds = 'name=$1; shift; for built in "${@:3}"; do [ -s "${built##*:}" ] || exit 0; done; "$@"; rc=$?; [ $rc -eq 0 ] || printf "FAIL solana %s: exit %d\\n" "$name" $rc; exit $rc';
const programSources = sources.concat([path("examples")]).concat(glob("tools/solana/*.ms"));
const replaySources = glob("tools/solana/*.mjs").concat([path("tools/solana/package-lock.json")]);
function program(name: string, entry: string, flags: string[], file: string): LazyPath {
	const command: Arg[] = ["bash", "-c", checked, "solana", name, candidate, "build", entry];
	for (const flag of flags) command.push(flag);
	return laneNode(`solana.${name}`, command, {}, programSources).addPrefixedOutputFileArg("--output=", file);
}
function replay(name: string, script: string, programs: LazyPath[], prefix: string = "", env: Record<string, Arg> = {}): void {
	const node = laneNode(`solana.${name}`, ["bash", "-c", afterBuilds, "solana", name, "node", `tools/solana/${script}.mjs`], env, replaySources);
	for (const built of programs) node.addPrefixedFileArg(prefix, built);
}
if (wanted("solana")) {
	const onChain = ["--os=solana"];
	const release = ["--os=solana", "--release"];
	replay("fields-replay", "accountValues", [program("fields-build", "tools/solana/accountValuesProbe.ms", release, "accountValues.so")]);
	const idlTool = program("idl-build", "examples/escrow/idl.cms", [], "escrow-idl");
	const idlRun = laneNode("solana.idl-run", ["bash", "-c", 'name=$1; [ -s "$2" ] || exit 0; "$2" >"$3"; rc=$?; [ $rc -eq 0 ] || printf "FAIL solana %s: exit %d\\n" "$name" $rc; exit $rc', "solana", "idl-run", idlTool], {}, []);
	const idl = idlRun.addOutputFileArg("escrow-idl.json");
	replay("escrow-replay", "escrow", [program("escrow-build", "examples/escrow/program.ms", onChain, "escrow.so"), idl]);
	replay("escrow-release-replay", "escrow", [program("escrow-release-build", "examples/escrow/program.ms", release, "escrowRelease.so"), idl]);
	replay("multisig-oncurve-replay", "anchorBench", [program("multisig-build", "examples/anchorBench/multisig/program.ms", release, "multisig.so")], "multisig:std:anchor:", { BENCH_REFUSALS: "1" });
	replay("heap-replay", "heapExhausted", [program("heap-build", "tools/solana/heapProbe.ms", onChain, "heapProbe.so")]);
	replay("resize-replay", "resizeAfterCpi", [program("resize-build", "tools/solana/resizeProbe.ms", onChain, "resizeProbe.so")]);
	replay("fidelity-replay", "hostFidelity", [program("fidelity-build", "tools/solana/hostFidelityProbe.ms", release, "hostFidelityProbe.so")]);
	replay("token-replay", "tokenOps", [program("token-build", "tools/solana/tokenOpsProbe.ms", release, "tokenOpsProbe.so")]);
	for (const pin of ["logText", "createAccountPrefund", "failFirst", "arrayCount", "tokenInterface", "pow"]) {
		replay(`${pin}-replay`, pin, [program(`${pin}-build`, `tools/solana/${pin}Probe.ms`, release, `${pin}Probe.so`)]);
	}
	replay("accountLimit-replay", "accountLimit", [
		program("accountLimit-build", "tools/solana/accountLimitProbe.ms", release.concat(["--passC=-DMS_SOL_MAX_ACCOUNTS=2"]), "accountLimit2.so"),
		program("accountLimit-default-build", "tools/solana/accountLimitProbe.ms", release, "accountLimit.so"),
	]);
}

const named = 'label=$1; shift; "$@"; rc=$?; [ $rc -eq 0 ] || printf "FAIL %s\\n" "$label"; exit $rc';
function tool(label: string, command: Arg[], inputs: LazyPath[]): LazyPath[] {
	const argv: Arg[] = ["bash", "-c", named, "tool", label];
	const name = `tools.${label.split("/").join("_").split(": ").join(".").split(" ").join("_")}`;
	return wanted(name) ? [laneNode(name, argv.concat(command), {}, inputs).captureStdOut()] : [];
}
for (const script of glob("tools/**/*.sh")) tool(`${script.sub}: bash -n`, ["bash", "-n", script], [script]);
tool("tools/gate.sh: self-test", ["bash", "tools/gate.sh", "--self-test"], [path("tools/gate.sh")]);
tool("tools/landQueueTest.sh: self-test", ["bash", "tools/landQueueTest.sh"], [path("tools/wt.sh"), path("tools/landQueue.sh"), path("tools/landQueueTest.sh")]);
tool("tools/releaseToolchainTest.sh: self-test", ["bash", "tools/releaseToolchainTest.sh"], [path("tools/release.sh"), path("tools/releaseToolchainTest.sh")]);
tool("tools/managedToolchain: self-test", ["python3", "-I", "-m", "unittest", "discover", "-s", "tools/managedToolchain", "-p", "*Test.py"], [path("tools/managedToolchain")]);

const toolSources = glob("tools/**/*.ms");
const inScratch = '"$@" "$(mktemp -u "${TMPDIR:-/tmp}/msc-tools.XXXXXX")"';
const windowsOnly = ["archiveBatchContractTest.ms", "windowsEngineProducerTest.ms"];
for (const source of toolSources) {
	const file = source.sub.split("/").pop();
	tool(`${source.sub}: check`, [candidate, "check", source], toolSources);
	if (!source.sub.startsWith("tools/managedToolchain/") || !file.endsWith("Test.ms") || windowsOnly.includes(file)) continue;
	if (file == "processContractTest.ms") tool(`${source.sub}: run`, ["bash", "-c", inScratch, "scratch", candidate, "run", source, "parent"], toolSources);
	else if (file == "nativePathTest.ms") tool(`${source.sub}: run`, ["bash", "-c", inScratch, "scratch", candidate, "run", source], toolSources);
	else if (file == "windowsRuntimeTest.ms") tool(`${source.sub}: run`, ["bash", "-c", inScratch, "scratch", candidate, "run", "--target=raiser", source], toolSources);
	else tool(`${source.sub}: run`, [candidate, "run", source], toolSources);
}
tool("tools/gateTest.ms: run", [candidate, "run", "tools/gateTest.ms", candidate], toolSources);

const installPinned = 'mkdir -p "$1/harness" "$1/vendor" && cp tools/bundler-plugin/harness/package.json tools/bundler-plugin/harness/package-lock.json "$1/harness/" && cp tools/bundler-plugin/vendor/rollup4.tgz "$1/vendor/" && npm ci --prefix "$1/harness" --ignore-scripts --prefer-offline --no-audit --no-fund';
const pins = [path("tools/bundler-plugin/harness/package.json"), path("tools/bundler-plugin/harness/package-lock.json"), path("tools/bundler-plugin/vendor/rollup4.tgz")];
const pinnedBundlers = systemCommand(["bash", "-c", installPinned, "bundlers"], { inputs: pins, description: "the pinned bundlers" }).addPrefixedOutputDirectoryArg("", "bundlers");
const adapters = glob("tools/bundler-plugin/*.js").concat(glob("tools/bundler-plugin/*.mjs")).concat(glob("tools/bundler-plugin/*.ts")).concat([path("tools/bundler-plugin/package.json"), path("src/test/js/declarationBundlers"), path("src/test/compat/typescript/run.mjs")]);
const withPinned = 'modules=$1/harness/node_modules; rm -rf tools/bundler-plugin/node_modules && ln -s "$modules" tools/bundler-plugin/node_modules && MSC=$2 VITE_MODULE=$modules/vite/dist/node/index.js ROLLUP_MODULE=$modules/rollup/dist/es/rollup.js WEBPACK_MODULE=$modules/webpack/lib/index.js TS_ORACLE_MODULE=$modules/typescript/lib/typescript.js node tools/bundler-plugin/test.mjs';
const adapterCheck: Arg[] = ["bash", "-c", withPinned, "adapters", pinnedBundlers, candidate];
const afterTheSelfTestRelinkedNodeModules = tool("tools/bundler-plugin/test.test.mjs: self-test", ["node", "--test", "--test-concurrency=1", "tools/bundler-plugin/test.test.mjs"], adapters.concat([path("tools/gate.sh")]));
tool("tools/bundler-plugin/test.mjs: check", adapterCheck, sources.concat(adapters).concat(afterTheSelfTestRelinkedNodeModules));

const gateTool = executable({ entry: path("tools/gate.ms"), optimize });
export const gate = systemCommand([gateTool, lanes.getDirectory(), path("src/test/known-red.json")], { expectExitCode: 0, description: "the verdict over the lane logs" });
