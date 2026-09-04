// Phase 1 spike benchmark — measure untagged register file speedup.
//
// Hand-builds two bytecode programs (sum, iterative Fibonacci) and runs
// them on both VMs back-to-back, reporting wall time and speedup ratio.
//
// Workloads (chosen to fit vm.ms's 10M op budget):
//   sum(1..N)        : ~5 ops/iter, dominated by AddI64 + BleI64 + Jump
//   fibIter(N)       : ~6 ops/iter, dominated by AddI64 + Move + BltI64 + Jump
//
// Both reduce to integer-only hot loops — no objects, strings, or calls.
// This isolates the boxing-allocation overhead the spike targets.
//
// Run:
//   msc run src/raiser/spike/bench.ms

import {
	RaiserOpcode, RaiserInstruction, raiserABC, raiserABx, raiserAx,
} from "../bytecode";
import { RaiserValue, raiserInt } from "../value";
import {
	RaiserModule, makeTestModule,
} from "../module";
import { execModule } from "../vm";
import { execFastModule } from "./vmFast";
import { execPackedModule } from "./vmPacked";

// --- Build sum(1..N) bytecode ---
//
//   r0 = sum (start 0), r1 = i (start 1), r2 = N, r3 = 1
//
//   LoadConst r0, 0
//   LoadConst r1, 1
//   LoadConst r2, N
//   LoadConst r3, 1
// loop:
//   BleI64 r1, r2, 1     ; if i <= N, skip 1 (skip the exit Jump)
//   Jump end
//   AddI64 r0, r0, r1    ; sum += i
//   AddI64 r1, r1, r3    ; i++
//   Jump loop
// end:
//   Halt r0

function buildSumModule(N: number): RaiserModule {
	const insts: RaiserInstruction[] = [];
	const consts: RaiserValue[] = [];
	consts.push(raiserInt(0));
	consts.push(raiserInt(1));
	consts.push(raiserInt(N));

	insts.push(raiserABx(RaiserOpcode.LoadConst, 0, 0));
	insts.push(raiserABx(RaiserOpcode.LoadConst, 1, 1));
	insts.push(raiserABx(RaiserOpcode.LoadConst, 2, 2));
	insts.push(raiserABx(RaiserOpcode.LoadConst, 3, 1));

	const loopStart = insts.length;
	insts.push(raiserABC(RaiserOpcode.BleI64, 1, 2, 1));
	const jumpEndIdx = insts.length;
	insts.push(raiserAx(RaiserOpcode.Jump, 0));

	insts.push(raiserABC(RaiserOpcode.AddI64, 0, 0, 1));
	insts.push(raiserABC(RaiserOpcode.AddI64, 1, 1, 3));

	const jumpBackIp = insts.length;
	const backOffset = loopStart - (jumpBackIp + 1);
	insts.push(raiserAx(RaiserOpcode.Jump, backOffset));

	const endIp = insts.length;
	const endOffset = endIp - (jumpEndIdx + 1);
	insts[jumpEndIdx] = raiserAx(RaiserOpcode.Jump, endOffset);

	insts.push(raiserABC(RaiserOpcode.Halt, 0, 0, 0));

	return makeTestModule(insts, consts);
}

// --- Build iterative fib(N) bytecode ---
//
//   r0 = a (0), r1 = b (1), r2 = i (0), r3 = N, r4 = 1, r5 = tmp
//
//   LoadConst r0, 0; LoadConst r1, 1; LoadConst r2, 0
//   LoadConst r3, N; LoadConst r4, 1
// loop:
//   BltI64 r2, r3, 1       ; if i < N, skip exit
//   Jump end
//   AddI64 r5, r0, r1      ; tmp = a + b
//   Move   r0, r1          ; a = b
//   Move   r1, r5          ; b = tmp
//   AddI64 r2, r2, r4      ; i++
//   Jump loop
// end:
//   Halt r1

function buildFibIterModule(N: number): RaiserModule {
	const insts: RaiserInstruction[] = [];
	const consts: RaiserValue[] = [];
	consts.push(raiserInt(0));
	consts.push(raiserInt(1));
	consts.push(raiserInt(N));

	insts.push(raiserABx(RaiserOpcode.LoadConst, 0, 0));
	insts.push(raiserABx(RaiserOpcode.LoadConst, 1, 1));
	insts.push(raiserABx(RaiserOpcode.LoadConst, 2, 0));
	insts.push(raiserABx(RaiserOpcode.LoadConst, 3, 2));
	insts.push(raiserABx(RaiserOpcode.LoadConst, 4, 1));

	const loopStart = insts.length;
	insts.push(raiserABC(RaiserOpcode.BltI64, 2, 3, 1));
	const jumpEndIdx = insts.length;
	insts.push(raiserAx(RaiserOpcode.Jump, 0));

	insts.push(raiserABC(RaiserOpcode.AddI64, 5, 0, 1));
	insts.push(raiserABC(RaiserOpcode.Move, 0, 1, 0));
	insts.push(raiserABC(RaiserOpcode.Move, 1, 5, 0));
	insts.push(raiserABC(RaiserOpcode.AddI64, 2, 2, 4));

	const jumpBackIp = insts.length;
	const backOffset = loopStart - (jumpBackIp + 1);
	insts.push(raiserAx(RaiserOpcode.Jump, backOffset));

	const endIp = insts.length;
	const endOffset = endIp - (jumpEndIdx + 1);
	insts[jumpEndIdx] = raiserAx(RaiserOpcode.Jump, endOffset);

	insts.push(raiserABC(RaiserOpcode.Halt, 1, 0, 0));

	return makeTestModule(insts, consts);
}

// --- Bench harness ---
// Validates correctness by comparing both VMs return the same value, then
// reports wall-clock ratio. Both runs single-pass (no warmup) — adequate
// for the spike since the speedup target is >5x.

// Round to 2 decimals as integer micros (MS lacks toFixed).
function fmtMs(ms: number): string {
	const micros: int64 = (ms * 1000.0) as int64;
	const whole: int64 = (micros / 1000) as int64;
	const frac: int64 = micros - whole * 1000;
	return `${whole}.${frac}`;
}

function runBench(name: string, mod: RaiserModule): void {
	const start1 = performance.now();
	const vm1 = execModule(mod);
	const ms1 = performance.now() - start1;
	const got1 = vm1.exitValue.intVal;

	const start2 = performance.now();
	const got2 = execFastModule(mod);
	const ms2 = performance.now() - start2;

	const start3 = performance.now();
	const got3 = execPackedModule(mod);
	const ms3 = performance.now() - start3;

	console.log(`\n=== ${name} ===`);
	console.log(`  vm.ms (boxed)        : ${fmtMs(ms1)}ms  result=${got1}`);
	console.log(`  vmFast (untag)       : ${fmtMs(ms2)}ms  result=${got2}`);
	console.log(`  vmPacked (untag+pak) : ${fmtMs(ms3)}ms  result=${got3}`);

	if (got1 !== got2 || got2 !== got3) {
		console.log(`  MISMATCH: vm.ms=${got1} vmFast=${got2} vmPacked=${got3}`);
		return;
	}
	if (ms2 > 0.0) {
		const r2 = ms1 / ms2;
		console.log(`  speedup vmFast   : ${fmtMs(r2)}x`);
	}
	if (ms3 > 0.0) {
		const r3 = ms1 / ms3;
		console.log(`  speedup vmPacked : ${fmtMs(r3)}x`);
	}
	if (ms3 > 0.0) {
		const r4 = ms2 / ms3;
		console.log(`  packing alone    : ${fmtMs(r4)}x  (vmFast → vmPacked)`);
	}
}

// --- Run ---

console.log("Raiser Phase 1 spike — untagged register file");
console.log("============================================");

// sum(1..N): gauss = N*(N+1)/2. Cap at 60000 so result fits int32.
runBench("sum(1..20000)", buildSumModule(20000));
runBench("sum(1..60000)", buildSumModule(60000));

// fibIter — values grow fast: fib(46) ~ 1.8e9 is last fitting int32.
runBench("fibIter(45)", buildFibIterModule(45));

console.log("\nNote: vm.ms budgets loop back-edges (10M iterations, not raw instructions).");
console.log("vmFast runs to 100M for headroom.");
