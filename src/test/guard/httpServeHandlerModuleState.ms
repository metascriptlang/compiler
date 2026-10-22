// guard: a request handler that answers through std/http/server reaches no module state of the
// server, so a program that hands it to serveConcurrent / serveConcurrentAsync checks clean.
//
// WHY A SUBPROCESS: the module-state rule is a warning, and the claim is that it stays silent
//   for these programs; GUARD-CHECK-FAIL can only claim an error.
//
// RED MEANS: the keep-alive timeout (or other per-server state) went back to a module-level
//   `let` that the response path reads, or the server type stopped checking.

import { execFileResult, cwd, exit, env } from "std/process";
import { ensureDir, isFile, writeFile } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const MODULE_STATE_RULE = "module state crosses threads only as";

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

if (!isFile(msc)) {
	console.log(`GUARD-FAIL compiler under test not found: ${msc}`);
	exit(1);
}

interface Case {
	name: string;
	text: string;
}

const cases: Case[] = [
	{
		name: "serveConcurrent with a handler that calls sendText",
		text: "import { createServer, serveConcurrent, sendText } from \"std/http/server\";\n"
			+ "import { HttpRequest, ServerResponse } from \"std/http/types\";\n"
			+ "function handle(req: HttpRequest, res: ServerResponse): void { sendText(res, \"ok\"); }\n"
			+ "const server = createServer(handle);\n"
			+ "console.log(typeof serveConcurrent, server.port);\n",
	},
	{
		name: "serveConcurrentAsync with an async handler that calls sendJson",
		text: "import { createServerAsync, serveConcurrentAsync, sendJson } from \"std/http/server\";\n"
			+ "import { HttpRequest, ServerResponse } from \"std/http/types\";\n"
			+ "async function handle(req: HttpRequest, res: ServerResponse): Promise<void> { sendJson(res, \"{}\"); }\n"
			+ "const server = createServerAsync(handle);\n"
			+ "console.log(typeof serveConcurrentAsync, server.port);\n",
	},
];

let slot = 0;
for (const c of cases) {
	slot += 1;
	const dir = `${root}/out/guard/httpServeHandlerModuleState/${slot}`;
	ensureDir(dir);
	writeFile(`${dir}/main.ms`, c.text);
	const r = execFileResult(msc, ["check", `${dir}/main.ms`]);
	const out = `${r.output}${r.errorOutput}`;
	if (r.exitCode != 0) report(`${c.name}: check failed: ${out}`);
	else if (out.includes(MODULE_STATE_RULE)) report(`${c.name}: module state reported: ${out}`);
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
