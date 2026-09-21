import { exists, ensureDir } from "std/fs";
import { join } from "std/fs/path";
import { execFile, env, exit } from "std/process";
import { exeSuffix } from "./io";
import { CliOptions } from "./options";
import { depRoots, cmdBuildC } from "./compile";
import { loadBuildConfig } from "./buildConfig";
import { binEntryFor } from "./package/bin";
import { cacheRoot } from "./package/cache";
import { findChar } from "../utils/string";
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

function packageKey(pkg: string, version: string, root: string): string {
	const safePkg = pkg.replace("/", "-");
	if (isImmutableRoot(root) && version != "") return `${safePkg}@${version}`;
	return safePkg;
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
	const binDir = join(cache, join("bin", packageKey(declared.packages[hit], declared.versions[hit], root)));
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
		opts.outputPath = binPath;
		opts.projectRoot = root;
		cmdBuildC(entryPath, opts, depCfg.resolve);
	}

	exit(execFile(binPath, forwarded));
	return true;
}
