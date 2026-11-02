// @stdout: 3
// @stdout: threw boom
// @stdout: 2
// @stdout: 11
// @stdout: caught [bad label]
// @stdout: ok 5
// @stdout: caught [bad é✓]
// @stdout: caught []
// @stdout: 3
import { guarded, finalsRun, recover } from "./callbackThrowWasm";

function fail(message: string): int32 {
	throw new Error(message);
}

function attempt(run: () => int32): string {
	try {
		return `${run()}`;
	} catch (e) {
		return `threw ${e.message}`;
	}
}

console.log(attempt(() => guarded(1, (x: int32): int32 => x * 2)));
console.log(attempt(() => guarded(1, (x: int32): int32 => fail("boom"))));
console.log(`${finalsRun()}`);
console.log(attempt(() => guarded(5, (x: int32): int32 => x * 2)));
console.log(recover("label", (s: string): int32 => fail("bad " + s)));
console.log(recover("abc", (s: string): int32 => s == "abc" ? 5 : 0));
console.log(recover("é✓", (s: string): int32 => fail("bad " + s)));
console.log(recover("", (s: string): int32 => fail(s)));
console.log(`${finalsRun()}`);
