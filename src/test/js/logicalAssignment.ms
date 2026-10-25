// JS: `&&=`, `||=` and `??=` are emitted as written, because the target has them and each
// evaluates its place once. Values: lang/logicalAssignment.ms and the corpus program
// logicalAssignment.ms.

import { compileToJS } from "../helpers";

const BOX = "class Box { x: int32 | null = null; y: int32 = 0; }\nconst box = new Box();\nfunction fetchBox(): Box { return box; }\nfunction seven(): int32 { return 7; }\n";

test "a nullish logical assignment on a field reached through a call is emitted as written" {
	const js = compileToJS(BOX + "fetchBox().x ??= seven();");
	assert js.ok;
	assert js.value.contains(".x ??= ");
}

test "an or and an and logical assignment are emitted as written" {
	const js = compileToJS("let n: int32 = 0;\nn ||= 5;\nn &&= 6;");
	assert js.ok;
	assert js.value.contains("||= ");
	assert js.value.contains("&&= ");
}
