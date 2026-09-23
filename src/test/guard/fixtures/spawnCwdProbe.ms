import { execFileCapture, cwd, exit, env } from "std/process";
import { ensureDir, writeFile } from "std/fs";

const msc = env.get("MSC");
const dir = `${cwd()}/out/spawnCwd/${env.get("SPAWN_CWD_TARGET")} dir`;
ensureDir(dir);
writeFile(`${dir}/spawnCwdChild.ms`, "const probe: int32 = 1;\n");

const inside = execFileCapture(msc, ["check", "spawnCwdChild.ms"], dir);
if (!inside.ok) {
	console.log(`GUARD-FAIL child did not run in ${dir}: ${inside.error.output}${inside.error.errorOutput}`);
	exit(1);
}
const outside = execFileCapture(msc, ["check", "spawnCwdChild.ms"]);
if (outside.ok) {
	console.log("GUARD-FAIL control: the child found spawnCwdChild.ms without a cwd");
	exit(1);
}
console.log("SPAWN-CWD-OK");
