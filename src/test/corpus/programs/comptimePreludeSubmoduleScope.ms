// @stdout: {"a":[1,true,"x"]} ["\ud800"] 42 | {"a":[1,true,"x"]} ["\ud800"] 42
// note: a std routine whose home is a prelude submodule runs at comptime in that submodule's scope (parseJson → skipWs and DEPTH_LIMIT, stringify → WTF8_SURROGATE_LEAD, parseInt → skipSpace) and answers what the same call answers at runtime.
function roundTrip(text: string): string {
	const r = parseJson(text);
	return r.ok ? stringify(r.value) : r.error;
}
const nested = @comptime { return roundTrip("{\"a\":[1,true,\"x\"]}"); };
const lone = @comptime { return roundTrip("[\"\\ud800\"]"); };
const prefix = @comptime { return "  42px".parseInt(); };
console.log(`${nested} ${lone} ${prefix} | ${roundTrip("{\"a\":[1,true,\"x\"]}")} ${roundTrip("[\"\\ud800\"]")} ${"  42px".parseInt()}`);
