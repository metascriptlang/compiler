import { evalSourceFull } from "../../codegen/raiser/eval";
import { RaiserContext } from "../../raiser/context";

function integerNullableLoop(iterations: int32): RaiserContext {
	return evalSourceFull(`
		@noinline function maybe(i: int64): int64 | null {
			return (i & 1) == 0 ? i : null;
		}
		@noinline function forward(i: int64): int64 | null {
			return maybe(i);
		}
		function run(n: int64): int64 {
			let sum: int64 = 0;
			for (let i: int64 = 0; i < n; i++) {
				const value = forward(i);
				if (value != null) sum += value;
			}
			return sum;
		}
		return run(${iterations});
	`);
}

function booleanNullableLoop(iterations: int32): RaiserContext {
	return evalSourceFull(`
		@noinline function maybe(i: int64): boolean | null {
			return (i & 1) == 0 ? false : null;
		}
		@noinline function forward(i: int64): boolean | null { return maybe(i); }
		function run(n: int64): int64 {
			let sum: int64 = 0;
			for (let i: int64 = 0; i < n; i++) {
				const value = forward(i);
				if (value != null) sum += value ? 1 : 3;
			}
			return sum;
		}
		return run(${iterations});
	`);
}

function floatNullableLoop(iterations: int32): RaiserContext {
	return evalSourceFull(`
		@noinline function maybe(i: int64): float64 | null {
			return (i & 1) == 0 ? (i as float64) + 0.25 : null;
		}
		@noinline function forward(i: int64): float64 | null {
			try { return maybe(i); } finally { const done = 1; }
		}
		function run(n: int64): float64 {
			let sum: float64 = 0;
			for (let i: int64 = 0; i < n; i++) {
				const value = forward(i);
				if (value != null) sum += value;
			}
			return sum;
		}
		return run(${iterations});
	`);
}

function structLoop(iterations: int32): RaiserContext {
	return evalSourceFull(`
		struct Pair { x: int64; y: float64; }
		@noinline function make(i: int64): Pair {
			return { x: i, y: (i as float64) + 0.5 };
		}
		@noinline function forward(value: Pair): Pair { return value; }
		function run(n: int64): float64 {
			let sum: float64 = 0;
			for (let i: int64 = 0; i < n; i++) {
				const value = forward(make(i));
				const copied = value;
				sum += (copied.x as float64) + copied.y;
			}
			return sum;
		}
		return run(${iterations});
	`);
}

function allocationDelta(small: RaiserContext, large: RaiserContext): int64 {
	return large.vm!.arrayHeap.mem.allocations -
		small.vm!.arrayHeap.mem.allocations;
}

test "an int64 nullable crosses nested calls without a box per iteration" {
	const small = integerNullableLoop(2);
	const large = integerNullableLoop(200);
	assert small.lastError == "", small.lastError;
	assert large.lastError == "", large.lastError;
	assert small.vm != null && large.vm != null;
	assert small.lastResult.intVal == 0 && large.lastResult.intVal == 9900;
	const delta = allocationDelta(small, large);
	assert delta == 0, `${delta} additional heap allocations`;
}

test "a one-word boolean nullable keeps false present across calls without a box per iteration" {
	const small = booleanNullableLoop(2);
	const large = booleanNullableLoop(200);
	assert small.lastError == "", small.lastError;
	assert large.lastError == "", large.lastError;
	assert small.vm != null && large.vm != null;
	assert small.lastResult.intVal == 3 && large.lastResult.intVal == 300;
	const delta = allocationDelta(small, large);
	assert delta == 0, `${delta} additional heap allocations`;
}

test "a float64 nullable returns through finally without a box per iteration" {
	const small = floatNullableLoop(2);
	const large = floatNullableLoop(200);
	assert small.lastError == "", small.lastError;
	assert large.lastError == "", large.lastError;
	assert small.vm != null && large.vm != null;
	assert small.lastResult.floatVal == 0.25 && large.lastResult.floatVal == 9925;
	const delta = allocationDelta(small, large);
	assert delta == 0, `${delta} additional heap allocations`;
}

test "an unmanaged struct crosses arguments returns and assignment without a cell per iteration" {
	const small = structLoop(2);
	const large = structLoop(200);
	assert small.lastError == "", small.lastError;
	assert large.lastError == "", large.lastError;
	assert small.vm != null && large.vm != null;
	assert small.lastResult.floatVal == 3.0 && large.lastResult.floatVal == 39900;
	const delta = allocationDelta(small, large);
	assert delta == 0, `${delta} additional heap allocations`;
}
