// @skip-raiser: the compile-time bridge of envPairs is built by a compiler whose own std has it, so it lands after the next sync
// @stdout: set=a=b c
// @stdout: deleted=absent
// @stdout: PATH is the one get reads=true
// @exit: 0

import { env, envPairs } from "std/process";

env.set("MSCORPUS_LISTED", "a=b c");
env.set("MSCORPUS_DELETED", "x");
env.delete("MSCORPUS_DELETED");
const listed = envPairs();
let path = "";
for (const name of listed.keys()) {
	if (name.toUpperCase() == "PATH") path = listed.get(name) ?? "";
}
console.log(`set=${listed.get("MSCORPUS_LISTED") ?? "<absent>"}`);
console.log(`deleted=${listed.has("MSCORPUS_DELETED") ? "listed" : "absent"}`);
console.log(`PATH is the one get reads=${path != "" && path == env.get("PATH")}`);
