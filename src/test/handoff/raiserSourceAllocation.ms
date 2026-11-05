import { evalSourceFull } from "../../codegen/raiser/eval";

function truthyLoop(iterations: int32): int64 {
	const ctx = evalSourceFull(`
		@noinline function value(n: int64): int64 | null { return n; }
		function run(n: int64): int64 {
			let sum: int64 = 0;
			for (let i: int64 = 0; i < n; i++) { const v = value(i); if (v) sum++; }
			return sum;
		}
		return run(${iterations});
	`);
	if (ctx.lastError != "") throw new Error(ctx.lastError);
	if (ctx.lastResult.intVal != (iterations - 1) as int64) throw new Error("wrong truthy sum");
	return ctx.vm!.arrayHeap.mem.allocations;
}

test "packed source: ordinary nullable conditions allocate no per-iteration carrier" {
	assert truthyLoop(200) - truthyLoop(2) == 0;
}
