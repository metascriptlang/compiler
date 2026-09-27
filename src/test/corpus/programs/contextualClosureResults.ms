// @stdout: results ok:42 ok:17 err:nope ok:9 ok:3 err:off true

interface Builder { listen: () => Result<int32, string>; }
interface Predicate { test: () => boolean; }

function show(result: Result<int32, string>): string {
	return result.ok ? "ok:" + result.value.toString() : "err:" + result.error;
}

function choose(on: boolean): Result<int32, string> {
	const callback: () => Result<int32, string> = () => {
		if (on) return Result.ok(3);
		return Result.err("off");
	};
	return callback();
}

const direct: () => Result<int32, string> = () => Result.ok(42);
const builder: Builder = { listen: () => Result.ok(17) };
const failed: () => Result<int32, string> = () => Result.err("nope");
const block: () => Result<int32, string> = () => { const value: int32 = 9; return Result.ok(value); };
const predicate: Predicate = { test: () => true };
console.log(`results ${show(direct())} ${show(builder.listen())} ${show(failed())} ${show(block())} ${show(choose(true))} ${show(choose(false))} ${predicate.test()}`);
