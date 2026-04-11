// msc publish — publish a package to the registry.
//
// Reads package metadata from build.ms, validates required fields,
// and prints the publish plan. Actual HTTP upload requires std/http
// (C compilation) or the registry server running locally.

import { exists } from "std/fs";
import { join } from "std/fs/path";
import { loadBuildConfig } from "../buildConfig";
import { loadToken } from "./login";

export function cmdPublish(projectRoot: string): boolean {
	const buildPath = join(projectRoot, "build.ms");
	if (!exists(buildPath)) {
		console.log("error: no build.ms found in project root");
		return false;
	}

	const cfg = loadBuildConfig(buildPath, false);
	if (!cfg.valid) {
		console.log("error: failed to parse build.ms");
		return false;
	}

	if (!cfg.package.valid) {
		console.log("error: build.ms must have a `package` section with at least `name`");
		console.log("example:");
		console.log("  package: { name: \"my-lib\", version: \"1.0.0\" },");
		return false;
	}

	if (cfg.package.version === "") {
		console.log("error: package.version is required for publishing");
		return false;
	}

	// Check auth
	const token = loadToken();
	if (token === "") {
		console.log("error: not logged in");
		console.log("run `msc login` first to authenticate");
		return false;
	}

	// Print publish plan
	console.log("Publishing to MetaScript Registry:");
	console.log(`  name:    ${cfg.package.name}`);
	console.log(`  version: ${cfg.package.version}`);
	if (cfg.package.description !== "") {
		console.log(`  desc:    ${cfg.package.description}`);
	}
	if (cfg.package.license !== "") {
		console.log(`  license: ${cfg.package.license}`);
	}
	console.log("");

	// For v1: actual upload requires std/http (C compilation)
	console.log("note: registry upload requires the compiled msc binary");
	console.log("      (std/http is not available in the Bun development runner)");
	console.log("");
	console.log("To publish manually, create a tarball and POST to the registry:");
	console.log(`  tar czf ${cfg.package.name}-${cfg.package.version}.tar.gz --exclude=out --exclude=.git .`);
	console.log(`  curl -X POST https://api.metascriptlang.org/packages \\`);
	console.log(`    -H "Authorization: Bearer <token>" \\`);
	console.log(`    -F "metadata=@metadata.json" \\`);
	console.log(`    -F "tarball=@${cfg.package.name}-${cfg.package.version}.tar.gz"`);
	return true;
}
