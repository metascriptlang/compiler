// Route 15j: Checker — the Maybe carrier of a function payload is keyed by the whole payload, pointees included

import { strictErrorCount } from "./helpers";

const SRC = "interface Box { w: number; }\ninterface Pt { x: number; }\n"
	+ "function pick<T>(fn: () => T, equals: ((a: T, b: T) => boolean) | null = null): T { const v = fn(); if (equals !== null && equals(v, v)) { return v; } return v; }\n";
const BOX = "const b = pick((): Box => { const o: Box = { w: 1 }; return o; });\n";
const PT = "const p = pick((): Pt => { const o: Pt = { x: 2 }; return o; });\n";

test "two struct instantiations of a nullable function formal each check against their own pointee" {
	assert strictErrorCount(SRC + BOX + PT) == 0;
	assert strictErrorCount(SRC + PT + BOX) == 0;
}

test "a primitive instantiation before the struct ones changes nothing" {
	assert strictErrorCount(SRC + "const n = pick((): number => 1);\n" + BOX + PT) == 0;
}
