// nim-guard: a capture spawn never waits on a process it did not start. Nim keeps the
// handles its stdlib creates non-inheritable (changelog 1.4, syncio `setInheritable`);
// the capture pipes follow it, and pipe creation never interleaves with another
// thread's spawn (runtime/process.h `_msSpawnCreateLock`, as on Windows).
//
// RED PRE-FIX: some captures wait ~2 s for a grandchild that inherited their write end.
// GREEN POST-FIX: no capture waits on the grandchildren.

import { execFile, execFileResult, exit, platform } from "std/process";

if (platform == "windows") {
	console.log("GUARD-OK windows: the probe drives /bin/sh");
	exit(0);
}

const spawner = spawn((): int32 => {
	for (let i = 0; i < 300; i++) execFile("/bin/sh", ["-c", "sleep 2 </dev/null >/dev/null 2>&1 &"]);
	return 0;
});
let blocked = 0;
for (let i = 0; i < 800; i++) {
	const t0 = performance.now();
	execFileResult("/bin/echo", ["x"]);
	if (performance.now() - t0 >= 1500) blocked++;
}
await spawner;
if (blocked != 0) {
	console.log(`GUARD-FAIL ${blocked} of 800 captures waited on a grandchild that inherited their pipe`);
	exit(1);
}
console.log("GUARD-OK");
