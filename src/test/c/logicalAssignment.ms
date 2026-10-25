// E2E C: `&&=`, `||=` and `??=` have no C spelling; the place's call or index is bound once,
// then a test guards the write. The values: lang/logicalAssignment.ms and the corpus program
// logicalAssignment.ms.

import { compileToC } from "../helpers";

const BOX = "class Box { x: int32 | null = null; y: int32 = 0; }\nconst box = new Box();\nfunction fetchBox(): Box { return box; }\nfunction seven(): int32 { return 7; }\n";

test "E2E C: a field place reached through a call binds the call to a temp before the test" {
	const c = compileToC(BOX + "fetchBox().x ??= seven();");
	assert c.ok;
	assert c.value.contains("__once_");
	assert !c.value.contains("??=");
}

test "E2E C: an element place with a call index binds the index to a temp" {
	const c = compileToC("let k = 0;\nfunction idx(): int32 { k += 1; return 0; }\nconst xs: int32[] = [0];\nxs[idx()] ||= 3;");
	assert c.ok;
	assert c.value.contains("__once_");
	assert !c.value.contains("||=");
}

test "E2E C: a name place needs no temp" {
	const c = compileToC("let n: int32 = 0;\nn &&= 5;\nn ||= 6;");
	assert c.ok;
	assert !c.value.contains("__once_");
	assert !c.value.contains("&&=");
}
