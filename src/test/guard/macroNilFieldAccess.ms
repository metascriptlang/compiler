// GUARD-CHECK-FAIL attempt to access a nil address

import { readAbsent } from "./fixtures/macroNilField/readAbsent";

function f(): void {
	readAbsent(0);
}

f();
