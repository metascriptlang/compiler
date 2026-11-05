// @stdout: arrays 1001 true
// @stdout: arrays 1002 Maximum nesting depth exceeded at position 1001
// @stdout: objects 1001 true
// @stdout: objects 1002 Maximum nesting depth exceeded at position 5005
// @stdout: objects 100000 Maximum nesting depth exceeded at position 5005
// @stdout: arrays 100000 Maximum nesting depth exceeded at position 1001
// @stdout: round trip 1001 2003
// @stdout: stringify built 3000 24001
// note: JSON.parse nests 1001 containers (the outermost is depth 0, Nim's DepthLimit) and refuses the next with an error, never a stack or VM overflow, on every lane; stringify writes a deeper tree built in code.
import { jsonArray, jsonInt, jsonObject } from "std/serialize/json/builder";

function nested(open: string, inner: string, close: string, levels: int32): string {
	let out = "";
	for (let i = 0; i < levels; i = i + 1) out = out + open;
	out = out + inner;
	for (let i = 0; i < levels; i = i + 1) out = out + close;
	return out;
}

function report(label: string, text: string): void {
	const r = JSON.parseValue(text);
	console.log(r.ok ? `${label} true` : `${label} ${r.error}`);
}

report("arrays 1001", nested("[", "", "]", 1001));
report("arrays 1002", nested("[", "", "]", 1002));
report("objects 1001", nested("{\"a\":", "1", "}", 1001));
report("objects 1002", nested("{\"a\":", "1", "}", 1002));
report("objects 100000", nested("{\"a\":", "1", "}", 100000));
report("arrays 100000", nested("[", "", "]", 100000));
const deepest = JSON.parseValue(nested("[", "1", "]", 1001));
if (deepest.ok) console.log(`round trip 1001 ${stringify(deepest.value).length}`);
let built = jsonInt(1);
for (let i = 0; i < 3000; i = i + 1) built = jsonObject(["a"], [jsonArray([built])]);
console.log(`stringify built 3000 ${stringify(built).length}`);
