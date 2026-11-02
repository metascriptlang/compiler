// @stdout: 42
// @stdout: threw big
// @stdout: yes
// @stdout: denied no entry
// @stdout: threw tick
// @stdout: 1
// @stdout: 7
// @stdout: 2
// @stdout: 0
// @stdout: threw wasm blew 3
// @stdout: 0
// @stdout: threw wasm blew 2
// @stdout: 10
// @stdout: threw deep
// @stdout: 4
import { nested, wide, permit, guardedTick, ticksRun, explode, relay } from "./callbackThrowNestedWasm";

function failBig(message: string): int64 {
	throw new Error(message);
}

function failBool(message: string): boolean {
	throw new Error(message);
}

function failVoid(message: string): void {
	throw new Error(message);
}

function fail(message: string): int32 {
	throw new Error(message);
}

function attempt(run: () => string): string {
	try {
		return run();
	} catch (e) {
		return `threw ${e.message}`;
	}
}

console.log(attempt(() => `${wide(40, (x: int64): int64 => x + 1)}`));
console.log(attempt(() => `${wide(40, (x: int64): int64 => failBig("big"))}`));
console.log(permit(2.5, 3, (x: float64, y: int32): boolean => x > 2 && y == 3));
console.log(permit(2.5, 3, (x: float64, y: int32): boolean => failBool("no entry")));
console.log(attempt(() => `${guardedTick((): void => failVoid("tick"))}`));
console.log(`${ticksRun()}`);
console.log(attempt(() => `${guardedTick((): void => {})}`));
console.log(`${ticksRun()}`);
console.log(attempt(() => `${explode(0)}`));
console.log(attempt(() => `${explode(3)}`));
console.log(attempt(() => `${explode(0)}`));
console.log(attempt(() => `${relay(2, (c: int32): int32 => c + 1)}`));
console.log(attempt(() => `${relay(0, (c: int32): int32 => c + 10)}`));
console.log(attempt(() => `${nested(1, (x: int32): int32 => nested(x, (y: int32): int32 => fail("deep")))}`));
console.log(attempt(() => `${nested(1, (x: int32): int32 => nested(x, (y: int32): int32 => y + 1))}`));
