import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

const bundle = resolve(process.argv[2]);
await import(pathToFileURL(bundle).href);

function exitWith(leaks) {
	const env = { ...process.env };
	delete env.MSB_LEAKS;
	if (leaks !== null) env.MSB_LEAKS = leaks;
	return spawnSync("node", [bundle], { env, encoding: "utf8" }).status;
}

console.log(`leaks tolerated: exit ${exitWith(null)}`);
console.log(`MSB_LEAKS=error: exit ${exitWith("error")}`);
