import { compileToJS } from "../helpers";
import { TargetInfo } from "../../checker/types";

const avr: TargetInfo = { ptrSize: 2, floatSize: 4, cpu: "avr", os: "bare" };

test "sizeof folds on the js target exactly as on C" {
	const result = compileToJS("const w: int32 = sizeof(int32);\nconsole.log(w);");
	assert result.ok;
	assert result.value.contains("= 4");
}

test "sizeof with no compile-time layout is refused on the js target" {
	const result = compileToJS("struct Head { c: int8; x: int64 }\nconst w: int32 = sizeof(Head);\nconsole.log(w);", avr);
	assert !result.ok;
	assert result.error.contains("on the js target");
}
