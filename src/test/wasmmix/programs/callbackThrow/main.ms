// @stdout: 3
// @stdout: 1
// @stdout: ok 5
// @stdout: threw boom
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
console.log(`${finalsRun()}`);
console.log(recover("abc", (s: string): int32 => s == "abc" ? 5 : 0));
console.log(attempt(() => guarded(1, (x: int32): int32 => fail("boom"))));
