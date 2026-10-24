// Package commands that need nothing from the driver: login, logout, whoami, publish, org.
//
// add, remove and install sync command shims through compiler/x, so src/index.ms dispatches them.
// They, mvs and gitsource are imported here so the test runner finds their tests.

import { error } from "../../utils/color";
import { cmdLogin, cmdLogout, cmdWhoami } from "./login";
import { cmdPublish } from "./publish";
import { cmdOrg } from "./org";
import "./add";
import "./remove";
import "./install";
import "./mvs";
import "./gitsource";

// Runs one package command; false means it failed and the process exits 1.
export async function runPackageCommand(cmd: string, inputFile: string, extraArgs: string[], projectRoot: string): Promise<boolean> {
	return match (cmd) {
		"login" => {
			return await cmdLogin(projectRoot);
		},
		"logout" => cmdLogout(),
		"whoami" => cmdWhoami(extraArgs),
		"publish" => cmdPublish(projectRoot, extraArgs),
		"org" => cmdOrg(inputFile == "" ? extraArgs : [inputFile].concat(extraArgs)),
		_ => {
			console.log(`${error("error")}: ${cmd} is not a package command`);
			return false;
		},
	};
}
