import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

const bundle = resolve(process.argv[2]);
await import(pathToFileURL(bundle).href);

function exitWith(leaks, args = [bundle]) {
	const env = { ...process.env };
	delete env.MSB_LEAKS;
	if (leaks !== null) env.MSB_LEAKS = leaks;
	return spawnSync("node", args, { env, encoding: "utf8" }).status;
}

const own = `await import(${JSON.stringify(pathToFileURL(bundle).href)}); process.exitCode = 3;`;

console.log(`leaks tolerated: exit ${exitWith(null)}`);
console.log(`MSB_LEAKS=error: exit ${exitWith("error")}`);
console.log(`MSB_LEAKS=error keeps a program's own code: exit ${exitWith("error", ["--input-type=module", "-e", own])}`);
