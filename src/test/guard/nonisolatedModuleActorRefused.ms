// A module-level actor handle read by a spawn thunk crosses threads without a safe wrapper.
// A guard that compiles clean means the module-state boundary stopped refusing it.
//
// GUARD-CHECK-FAIL module state crosses threads only as a const value

import { nonisolated } from "std/actor";

actor Srv {
	@nonisolated
	readonly name: string = "s";
	ping(): int32 { return 1; }
}

const s = new Srv();
const r = spawn((): int64 => {
	const v = s.name;
	return v.length;
});
console.log(await r);
