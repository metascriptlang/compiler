import { exists, ensureDir, readFile, writeFile, chmod, readDir, remove, removeAll, rename } from "std/fs";
import { join } from "std/fs/path";
import { execFile, env, exit } from "std/process";
import { exeSuffix } from "./io";
import { CliOptions } from "./options";
import { depRoots, cmdBuildC } from "./compile";
import { loadBuildConfig } from "./buildConfig";
import { binEntryFor, commandNameError } from "./package/bin";
import { cacheRoot } from "./package/cache";
import { shimFileName, shimContent, isShim, SHIM_MODE } from "./package/shim";
import { cmdAdd } from "./package/add";
import { findChar } from "../utils/string";
import { dirEntryName, recordDirUse } from "../utils/lruDirs";
import { error as errStyle, bold, cyan, dim } from "../utils/color";


export function globalManifestRoot(): string {
	let home = env.get("HOME");
	if (home == "") home = env.get("USERPROFILE");
	if (home == "") return "";
	return join(home, ".metascript/global");
}

function isImmutableRoot(root: string): boolean {
	const cache = cacheRoot();
	if (cache == "") return false;
	return root.length > cache.length && root.slice(0, cache.length) == cache;
}

function searchRoots(projectRoot: string): { keys: string[], values: string[] } {
	const keys: string[] = [];
	const values: string[] = [];
	const local = depRoots(projectRoot);
	let i = 0;
	while (i < local.keys.length) {
		keys.push(local.keys[i]);
		values.push(local.values[i]);
		i = i + 1;
	}
	const globalRoot = globalManifestRoot();
	if (globalRoot != "" && globalRoot != projectRoot && exists(join(globalRoot, "build.ms"))) {
		const globals = depRoots(globalRoot);
		let g = 0;
		while (g < globals.keys.length) {
			let seen = false;
			for (const v of values) { if (v == globals.values[g]) seen = true; }
			if (!seen) {
				keys.push(globals.keys[g]);
				values.push(globals.values[g]);
			}
			g = g + 1;
		}
	}
	return { keys, values };
}

export function declaredCommands(projectRoot: string): { commands: string[], packages: string[], roots: string[], entries: string[], versions: string[] } {
	const commands: string[] = [];
	const packages: string[] = [];
	const roots: string[] = [];
	const entries: string[] = [];
	const versions: string[] = [];
	const found = searchRoots(projectRoot);
	let i = 0;
	while (i < found.keys.length) {
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
					versions.push(depCfg.package.version);
				}
			}
		}
		i = i + 1;
	}
	return { commands, packages, roots, entries, versions };
}

export function projectShimDir(projectRoot: string): string {
	return join(projectRoot, join(".msc", "bin"));
}

export function globalShimDir(): string {
	let home = env.get("HOME");
	if (home == "") home = env.get("USERPROFILE");
	if (home == "") return "";
	return join(home, join(".metascript", "bin"));
}

export function pruneStaleShims(shimDir: string, keep: string[]): int32 {
	if (!exists(shimDir)) return 0;
	let pruned = 0;
	for (const rawEntry of readDir(shimDir)) {
		const entry = dirEntryName(rawEntry);
		let isKeep = false;
		for (const k of keep) {
			if (k == entry) isKeep = true;
		}
		if (isKeep) continue;
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
	let i = 0;
	while (i < declared.commands.length) {
		const cmd = declared.commands[i];
		const nameErr = commandNameError(cmd);
		if (nameErr != "") {
			console.log(`${errStyle("error")}: ${declared.packages[i]}: ${nameErr}`);
			ok = false;
		}
		let j = 0;
		while (j < i) {
			if (declared.commands[j] == cmd) {
				console.log(`${errStyle("error")}: ${bold(cmd)} is declared by both ${declared.packages[j]} and ${declared.packages[i]}`);
				ok = false;
			}
			j = j + 1;
		}
		i = i + 1;
	}
	if (!ok) {
		console.log("no command was installed");
		return false;
	}

	ensureDir(shimDir);
	const keep: string[] = [];
	let written = 0;
	let s = 0;
	while (s < declared.commands.length) {
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
		s = s + 1;
	}
	console.log(`${written.toString()} command(s) installed in ${dim(shimDir)}`);
	const pruned = pruneStaleShims(shimDir, keep);
	if (pruned > 0) console.log(`pruned ${pruned.toString()} stale command(s)`);
	return true;
}

test "pruneStaleShims removes stale shims and leaves foreign files" {
	const base = env.get("TMPDIR");
	const dir = join(base != "" ? base : "/tmp", "msc-prune-shims-test");
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
		const addArgs: string[] = [spec];
		if (!cmdAdd(root, addArgs)) return false;
	}
	return syncShims(root, shimDir);
}

function packageKey(pkg: string, version: string, root: string): string {
	const safePkg = pkg.replace("/", "-");
	if (isImmutableRoot(root) && version != "") return `${safePkg}@${version}`;
	return safePkg;
}

let tmpBuildSeq: int32 = 0;

function tempBuildPath(binPath: string): string {
	tmpBuildSeq = tmpBuildSeq + 1;
	return `${binPath}.tmp${performance.now().toString()}.${tmpBuildSeq.toString()}`;
}

export const BIN_CACHE_CAP: int32 = 32;

export function cmdX(projectRoot: string, args: string[], opts: CliOptions): boolean {
	const declared = declaredCommands(projectRoot);

	if (args.length == 0) {
		if (declared.commands.length == 0) {
			console.log(`${errStyle("error")}: no dependency declares a command`);
			console.log(`a package declares one with ${cyan("package.bin")} in its build.ms`);
			return false;
		}
		console.log(bold("commands:"));
		let d = 0;
		while (d < declared.commands.length) {
			console.log(`  ${cyan(declared.commands[d])} ${dim(`(${declared.packages[d]})`)}`);
			d = d + 1;
		}
		return false;
	}

	const spec = args[0];
	const colon = findChar(spec, ":");
	const wantPkg = colon >= 0 ? spec.slice(0, colon) : "";
	const wantCmd = colon >= 0 ? spec.slice(colon + 1, spec.length) : spec;

	const hits: int32[] = [];
	let i = 0;
	while (i < declared.commands.length) {
		if (declared.commands[i] == wantCmd && (wantPkg == "" || declared.packages[i] == wantPkg)) {
			hits.push(i);
		}
		i = i + 1;
	}

	if (hits.length == 0) {
		console.log(`${errStyle("error")}: no dependency declares the command ${bold(wantCmd)}`);
		if (declared.commands.length > 0) {
			let known = "";
			for (const c of declared.commands) { known = known == "" ? c : `${known}, ${c}`; }
			console.log(`declared here: ${known}`);
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

	const cache = cacheRoot();
	if (cache == "") {
		console.log(`${errStyle("error")}: cannot locate ~/.metascript — set HOME`);
		return false;
	}
	const key = packageKey(declared.packages[hit], declared.versions[hit], root);
	const binDir = join(cache, join("bin", key));
	const binPath = join(binDir, wantCmd + exeSuffix());

	const forwarded: string[] = [];
	let f = 1;
	while (f < args.length) {
		forwarded.push(args[f]);
		f = f + 1;
	}

	if (!isImmutableRoot(root) || !exists(binPath)) {
		ensureDir(binDir);
		const depCfg = loadBuildConfig(join(root, "build.ms"), false);
		const tmpPath = tempBuildPath(binPath);
		opts.outputPath = tmpPath;
		opts.projectRoot = root;
		cmdBuildC(entryPath, opts, depCfg.resolve);
		const moved = rename(tmpPath, binPath);
		if (!moved.ok) {
			remove(tmpPath);
			console.log(`${errStyle("error")}: cannot finalize ${binPath}: ${moved.error.message}`);
			return false;
		}
	}
	recordDirUse(join(cache, "bin"), key, BIN_CACHE_CAP);

	exit(execFile(binPath, forwarded));
	return true;
}
