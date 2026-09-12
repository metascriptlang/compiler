// Route 15h: Checker — a tagged-union parameter is a representation mismatch inside a function slot

import { strictErrorCount } from "./helpers";

const SETTER = "type Setter<T> = (v: T | ((prev: T) => T)) => void;\nconst s: Setter<number> = (v) => {};\n";

test "a value-or-updater setter does not fit a plain setter argument slot" {
	assert strictErrorCount(SETTER + "function take(f: (v: number) => void): void { f(1); }\ntake(s);") == 1;
}

test "a plain setter still fits a plain setter slot" {
	assert strictErrorCount("const p: (v: number) => void = (v: number) => {};\nfunction take(f: (v: number) => void): void { f(1); }\ntake(p);") == 0;
}

test "a nullable parameter still matches through the carrier" {
	assert strictErrorCount("const p: (v: number | null) => void = (v) => {};\nfunction take(f: (v: number | null) => void): void { f(1); }\ntake(p);") == 0;
}
