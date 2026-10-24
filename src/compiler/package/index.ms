// Package manager commands: msc add, remove, install, login, logout, whoami, publish, org.
//
// mvs and gitsource have no command yet; they are imported so the test runner finds their tests.

import { exists } from "std/fs";
import { join } from "std/fs/path";
import { CliOptions } from "../options";
import { syncShims, projectShimDir, cmdInstallGlobal, globalManifestRoot, globalShimDir } from "../x";
import { error, cyan } from "../../utils/color";
import { cmdAdd } from "./add";
import { cmdRemove } from "./remove";
import { cmdInstall } from "./install";
import { cmdLogin, cmdLogout, cmdWhoami } from "./login";
import { cmdPublish } from "./publish";
import { cmdOrg } from "./org";
import "./mvs";
import "./gitsource";

function commandArgs(opts: CliOptions): string[] {
	const args: string[] = [];
	if (opts.inputFile != "") args.push(opts.inputFile);
	for (const arg of opts.extraArgs) args.push(arg);
	return args;
}

function hasGlobalFlag(opts: CliOptions): boolean {
	for (const arg of opts.extraArgs) {
		if (arg == "-g" || arg == "--global") return true;
	}
	return false;
}

function removeDep(opts: CliOptions, projectRoot: string): boolean {
	const args: string[] = [];
	if (opts.inputFile != "") args.push(opts.inputFile);
	if (!hasGlobalFlag(opts)) return cmdRemove(projectRoot, args) && syncShims(projectRoot, projectShimDir(projectRoot));
	const root = globalManifestRoot();
	if (root == "" || !exists(join(root, "build.ms"))) {
		console.log(`${error("error")}: no global manifest — nothing was installed with ${cyan("install -g")}`);
		return false;
	}
	return cmdRemove(root, args) && syncShims(root, globalShimDir());
}

// Runs one package command; false means it failed and the process exits 1.
export async function runPackageCommand(cmd: string, opts: CliOptions, projectRoot: string): Promise<boolean> {
	return match (cmd) {
		"add" => cmdAdd(projectRoot, commandArgs(opts)) && syncShims(projectRoot, projectShimDir(projectRoot)),
		"remove" => removeDep(opts, projectRoot),
		"install" => {
			if (hasGlobalFlag(opts)) return cmdInstallGlobal(opts.inputFile);
			return cmdInstall(projectRoot) && syncShims(projectRoot, projectShimDir(projectRoot));
		},
		"login" => {
			return await cmdLogin(projectRoot);
		},
		"logout" => cmdLogout(),
		"whoami" => cmdWhoami(opts.extraArgs),
		"publish" => cmdPublish(projectRoot, opts.extraArgs),
		"org" => cmdOrg(commandArgs(opts)),
		_ => {
			console.log(`${error("error")}: ${cmd} is not a package command`);
			return false;
		},
	};
}
