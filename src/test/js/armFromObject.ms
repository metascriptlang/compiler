// An object converted into a union arm keeps one value on the js target: no routine rebuilds it.

import { compileToJS } from "../helpers";

test "an object converted into an arm is not rebuilt on the js target" {
	const result = compileToJS("type Pair = match (ok: boolean) { true => { value: string }, false => { error: string } };\nconst o: { ok: true; value: string } = { ok: true, value: \"x\" };\nfunction take(x: Pair): boolean { return x.ok; }\nconsole.log(take(o));");
	assert result.ok;
	assert !result.value.contains("msArmConv_");
}
