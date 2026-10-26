import { exists, ensureDir, readFile, writeFile, chmod, readDir, remove, removeAll } from "std/fs";
import { join } from "std/fs/path";
import { env } from "std/process";
import { CliOptions } from "./options";
import { depRoots, cmdRunRaiser } from "./compile";
import { loadBuildConfig } from "./buildConfig";
import { binEntryFor, commandNameError } from "./package/bin";
import { shimFileName, shimContent, isShim, SHIM_MODE } from "./package/shim";
import { cmdAdd } from "./package/add";
import { findChar } from "../utils/string";
import { error as errStyle, bold, cyan, dim } from "../utils/color";


function homeDir(): string | null {
	const home = env.get("HOME");
	if (home != "") return home;
	const profile = env.get("USERPROFILE");
	return profile != "" ? profile : null;
}

export function globalManifestRoot(): string {
	const home = homeDir();
	return home == null ? "" : join(home, ".metascript/global");
}

function dirEntryName(entry: string): string {
	if (entry.length > 1 && entry.endsWith("/")) {
		return entry.slice(0, entry.length - 1);
	}
	return entry;
}

function searchRoots(projectRoot: string): { keys: string[], values: string[] } {
	const local = depRoots(projectRoot);
	const keys = local.keys.slice(0, local.keys.length);
	const values = local.values.slice(0, local.values.length);
	const globalRoot = globalManifestRoot();
	if (globalRoot != "" && globalRoot != projectRoot && exists(join(globalRoot, "build.ms"))) {
		const globals = depRoots(globalRoot);
		for (let g = 0; g < globals.keys.length; g++) {
			if (!values.includes(globals.values[g])) {
				keys.push(globals.keys[g]);
				values.push(globals.values[g]);
			}
		}
	}
	return { keys, values };
}

function declaredCommands(projectRoot: string): { commands: string[], packages: string[], roots: string[], entries: string[] } {
	const commands: string[] = [];
	const packages: string[] = [];
	const roots: string[] = [];
	const entries: string[] = [];
	const found = searchRoots(projectRoot);
	for (let i = 0; i < found.keys.length; i++) {
		const root = found.values[i];
		const depBuild = join(root, "build.ms");
		if (exists(depBuild)) {
			const depCfg = loadBuildConfig(depBuild, false);
			if (depCfg.valid && depCfg.package.bin.keys.length > 0) {
				const pkgName = depCfg.package.name != "" ? depCfg.package.name : found.keys[i];
				for (const cmd of depCfg.package.bin.keys) {
					commands.push(cmd);
					packages.push(pkgName);
					roots.push(root);
					entries.push(binEntryFor(depCfg.package, cmd));
				}
			}
		}
	}
	return { commands, packages, roots, entries };
}

export function projectShimDir(projectRoot: string): string {
	return join(projectRoot, join(".msc", "bin"));
}

export function globalShimDir(): string {
	const home = homeDir();
	return home == null ? "" : join(home, join(".metascript", "bin"));
}

function pruneStaleShims(shimDir: string, keep: string[]): int32 {
	if (!exists(shimDir)) return 0;
	let pruned = 0;
	for (const rawEntry of readDir(shimDir)) {
		const entry = dirEntryName(rawEntry);
		if (keep.includes(entry)) continue;
		const shimPath = join(shimDir, entry);
		const content = try readFile(shimPath) catch "";
		if (isShim(content)) {
			if (remove(shimPath).ok) pruned = pruned + 1;
		}
	}
	return pruned;
}

export function syncShims(projectRoot: string, shimDir: string): boolean {
	const declared = declaredCommands(projectRoot);
	if (declared.commands.length == 0) {
		const pruned = pruneStaleShims(shimDir, []);
		if (pruned > 0) console.log(`pruned ${pruned.toString()} stale command(s) from ${dim(shimDir)}`);
		return true;
	}

	let ok = true;
	for (let i = 0; i < declared.commands.length; i++) {
		const cmd = declared.commands[i];
		const nameErr = commandNameError(cmd);
		if (nameErr != null) {
			console.log(`${errStyle("error")}: ${declared.packages[i]}: ${nameErr}`);
			ok = false;
		}
		for (let j = 0; j < i; j++) {
			if (declared.commands[j] == cmd) {
				console.log(`${errStyle("error")}: ${bold(cmd)} is declared by both ${declared.packages[j]} and ${declared.packages[i]}`);
				ok = false;
			}
		}
	}
	if (!ok) {
		console.log("no command was installed");
		return false;
	}

	ensureDir(shimDir);
	const keep: string[] = [];
	let written = 0;
	for (let s = 0; s < declared.commands.length; s++) {
		const cmd = declared.commands[s];
		const name = shimFileName(cmd);
		keep.push(name);
		const shimPath = join(shimDir, name);
		if (exists(shimPath)) {
			const current = try readFile(shimPath) catch "";
			if (!isShim(current)) {
				console.log(`${errStyle("error")}: ${shimPath} exists and was not written by msc — leaving it alone`);
				return false;
			}
		}
		const content = shimContent(declared.packages[s], cmd);
		const w = writeFile(shimPath, content);
		if (!w.ok) {
			console.log(`${errStyle("error")}: cannot write ${shimPath}: ${w.error.message}`);
			return false;
		}
		chmod(shimPath, SHIM_MODE);
		console.log(`  ${cyan(cmd)} ${dim(`(${declared.packages[s]})`)}`);
		written = written + 1;
	}
	console.log(`${written.toString()} command(s) installed in ${dim(shimDir)}`);
	const pruned = pruneStaleShims(shimDir, keep);
	if (pruned > 0) console.log(`pruned ${pruned.toString()} stale command(s)`);
	return true;
}

test "pruneStaleShims removes stale shims and leaves foreign files" {
	const base = env.get("TMPDIR");
	const dir = join(base != "" ? base : "/tmp", "msc-prune-shims-test-" + String(Math.floor(Math.random() * 1000000000)));
	removeAll(dir);
	ensureDir(dir);
	writeFile(join(dir, "greet"), "#!/bin/sh\n# msc shim v1\nexec msc x 'greeter:greet' \"$@\"\n");
	writeFile(join(dir, "old"), "#!/bin/sh\nexec msc x 'greeter:old' \"$@\"\n");
	writeFile(join(dir, "mine"), "#!/bin/sh\necho mine\n");
	const pruned = pruneStaleShims(dir, ["greet"]);
	assert pruned == 1;
	assert exists(join(dir, "greet"));
	assert exists(join(dir, "mine"));
	assert !exists(join(dir, "old"));
	removeAll(dir);
}

const GLOBAL_MANIFEST = "import { BuildConfig } from \"std/build\";\n\nconst config: BuildConfig = {\n\tpackage: { name: \"metascript-global\", version: \"0.0.0\" },\n\tdeps: {\n\t},\n};\n\nexport default config;\n";

export function cmdInstallGlobal(spec: string): boolean {
	const root = globalManifestRoot();
	if (root == "") {
		console.log(`${errStyle("error")}: cannot locate ~/.metascript — set HOME`);
		return false;
	}
	const shimDir = globalShimDir();
	if (shimDir == "") {
		console.log(`${errStyle("error")}: cannot locate ~/.metascript/bin — set HOME`);
		return false;
	}
	ensureDir(root);
	const manifest = join(root, "build.ms");
	if (!exists(manifest)) {
		const w = writeFile(manifest, GLOBAL_MANIFEST);
		if (!w.ok) {
			console.log(`${errStyle("error")}: cannot write ${manifest}: ${w.error.message}`);
			return false;
		}
	}
	if (spec != "") {
		if (!cmdAdd(root, [spec])) return false;
	}
	return syncShims(root, shimDir);
}

export function cmdX(projectRoot: string, args: string[], opts: CliOptions): boolean {
	const declared = declaredCommands(projectRoot);

	if (args.length == 0) {
		if (declared.commands.length == 0) {
			console.log(`${errStyle("error")}: no dependency declares a command`);
			console.log(`a package declares one with ${cyan("package.bin")} in its build.ms`);
			return false;
		}
		console.log(bold("commands:"));
		for (let d = 0; d < declared.commands.length; d++) {
			console.log(`  ${cyan(declared.commands[d])} ${dim(`(${declared.packages[d]})`)}`);
		}
		return false;
	}

	const spec = args[0];
	const colon = findChar(spec, ":");
	const wantPkg = colon >= 0 ? spec.slice(0, colon) : "";
	const wantCmd = colon >= 0 ? spec.slice(colon + 1, spec.length) : spec;

	const hits: int32[] = [];
	for (let i = 0; i < declared.commands.length; i++) {
		if (declared.commands[i] == wantCmd && (wantPkg == "" || declared.packages[i] == wantPkg)) {
			hits.push(i);
		}
	}

	if (hits.length == 0) {
		console.log(`${errStyle("error")}: no dependency declares the command ${bold(wantCmd)}`);
		if (declared.commands.length > 0) {
			console.log(`declared here: ${declared.commands.join(", ")}`);
		}
		return false;
	}
	if (hits.length > 1) {
		console.log(`${errStyle("error")}: ${bold(wantCmd)} is declared by more than one package`);
		for (const h of hits) {
			console.log(`  ${declared.packages[h]} → ${declared.entries[h]}`);
		}
		console.log(`run it as ${cyan(`msc x <package>:${wantCmd}`)}`);
		return false;
	}

	const hit = hits[0];
	const root = declared.roots[hit];
	const entry = declared.entries[hit];
	const entryPath = join(root, entry);
	if (!exists(entryPath)) {
		console.log(`${errStyle("error")}: ${declared.packages[hit]} declares ${bold(wantCmd)} at ${entry}, which does not exist in ${root}`);
		return false;
	}

	opts.projectRoot = root;
	opts.extraArgs = args.slice(1, args.length);
	cmdRunRaiser(entryPath, opts, loadBuildConfig(join(root, "build.ms"), false).resolve, wantCmd);
	return true;
}
