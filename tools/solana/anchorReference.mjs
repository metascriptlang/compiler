import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve, join } from "node:path";

const [cloneArg, workArg, format = "byte"] = process.argv.slice(2);
if (!cloneArg || !workArg || !["byte", "hash"].includes(format)) {
	throw new Error("usage: node anchorReference.mjs <reference-clone> <work-directory> [byte|hash]");
}
const clone = resolve(cloneArg);
const work = resolve(workArg);
const revision = "ff0514b6042e3cf7345bf0cd58eb442542c93172";
const root = join(work, "source");
if (existsSync(root)) throw new Error("source snapshot already exists; choose a fresh work-directory");
mkdirSync(root, { recursive: true });
execFileSync("git", ["-C", clone, "archive", revision, "--output=" + join(work, "reference.tar")]);
execFileSync("tar", ["-xf", join(work, "reference.tar"), "-C", root]);
const prop = join(root, "bench/programs/prop-amm/anchor-v2");
writeFileSync(join(prop, "src/lib.rs"), readFileSync(new URL("./checkedProp.rs", import.meta.url)));
const manifest = join(prop, "Cargo.toml");
writeFileSync(manifest, readFileSync(manifest, "utf8").replace(
	'default = ["no-entrypoint", "no-log-ix-name"]', 'default = ["no-log-ix-name"]'));
const suites = {
	helloworld: "hello_world_v2",
	vault: "vault_v2",
	nested: "nested_v2",
	"prop-amm": "prop_amm_v2",
	multisig: "multisig_v2",
};
const rows = [];
const toolchain = execFileSync("cargo-build-sbf", ["--version"], { encoding: "utf8" }).trim();
const featuresSha256 = createHash("sha256").update(readFileSync(new URL("./mainnetInactiveFeatures.json", import.meta.url))).digest("hex");
for (const [suite, library] of Object.entries(suites)) {
	const packageRoot = join(root, "bench/programs", suite, "anchor-v2");
	const source = join(packageRoot, "src/lib.rs");
	let code = readFileSync(source, "utf8");
	if (suite === "vault") {
		for (const instruction of ["deposit", "withdraw"]) {
			const signature = `pub fn ${instruction}(ctx: &mut Context<${instruction === "deposit" ? "Deposit" : "Withdraw"}>, amount: u64) -> Result<()> {`;
			if (!code.includes(signature)) throw new Error("vault fixture signature drifted");
			code = code.replace(signature, signature + "\n        if ctx.program_id != &crate::ID { return Err(ProgramError::Custom(4100)); }");
		}
	}
	if (format === "hash") code = code.replace(/^\s*#\[discrim = \d+\]\n/gm, "\n");
	else if (suite === "helloworld") code = code.replace(
		"    #[inline(always)]\n    pub fn init", "    #[discrim = 0]\n    #[inline(always)]\n    pub fn init");
	writeFileSync(source, code);
	const args = ["--manifest-path", join(packageRoot, "Cargo.toml"), "--tools-version", "v1.57", "--arch", "v3",
		"--sbf-out-dir", join(work, "deploy"), "--", "--offline"];
	const started = Date.now();
	let output;
	try { output = execFileSync("cargo-build-sbf", args, { encoding: "utf8", maxBuffer: 10_000_000, stdio: ["ignore", "pipe", "pipe"] }); }
	catch (error) {
		writeFileSync(join(work, suite + ".build.log"), String(error.stdout ?? "") + String(error.stderr ?? ""));
		throw error;
	}
	writeFileSync(join(work, suite + ".build.log"), output);
	const artifact = readFileSync(join(work, "deploy", library + ".so"));
	rows.push({ suite, bytes: artifact.length, sha256: createHash("sha256").update(artifact).digest("hex"),
		seconds: (Date.now() - started) / 1000, command: ["cargo-build-sbf", ...args] });
	writeFileSync(join(work, "manifest.json"), JSON.stringify({ revision, format,
		architecture: "v3 (same ELF ISA flag3 as SDK)", toolchain, featuresSha256,
		checkedVault: "explicit ctx.program_id == crate::ID guard; upstream guardrails disabled",
		runtimeFeatures: "tools/solana/mainnetInactiveFeatures.json (execution harness)",
		profile: { opt: 3, lto: "fat", codegenUnits: 1, overflowChecks: false },
		checkedPropSourceSha256: createHash("sha256").update(readFileSync(new URL("./checkedProp.rs", import.meta.url))).digest("hex"), rows }, null, 2) + "\n");
	console.log(suite, artifact.length, "B", rows.at(-1).sha256);
}
