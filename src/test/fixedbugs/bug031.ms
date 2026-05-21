// bug031 — break/continue inside async while-loop never completed the future
//
// Symptom:    `async function f() { while (...) { await ...; if (cond) break; } }`
//             would deadlock the caller. With a real I/O loop, the function
//             body would print up to the break-condition iteration, but the
//             returned Promise never resolved — caller's `await f()` hung
//             forever. With `keepAlive=false` HTTP server, this manifested
//             as the keep-alive teardown path running forever instead of
//             closing the connection.
//
// Root cause: `src/transform/lowering/generatorLower.ms splitStmts` did not
//             recognise `BreakStmt`/`ContinueStmt` as state transitions.
//             Both fell into the `!containsYield` catch-all and were pushed
//             AS-IS into the state body. The lowered C state-machine looks
//             like:
//                 while (1) {                          // outer dispatcher
//                     if ($state == N) { ...; break; }
//                     ...
//                 }
//             so the bare C `break;` exits the outer `while(1)` instead of
//             transitioning $state. The function then fell through to its
//             tail (`return MS_NIL;`) WITHOUT calling `msFutureCompleteT`
//             on `$retFut`. Caller's `await f()` sees an un-completed future
//             and waits indefinitely.
//
// Fix:        Add `loopStack: LoopFrame[]` to `StateCollector`. `splitWhile`
//             pushes `{ breakState, continueState }` before recursing into
//             the body. `splitStmts` rewrites direct break/continue as
//             `$state = N;` + early-return (dead-code skip). Nested
//             break/continue inside pushed-as-is stmts (e.g. `if (x) break;`
//             where the if has no yield) is rewritten via `rewriteLoopExits`
//             walker into `{ $state = N; continue; }` — the trailing
//             `continue;` is a bare C continue that exits the state-body
//             iteration so the rest of the state body doesn't overwrite
//             `$state` before the dispatcher re-evaluates. Walker stops at
//             nested loops/switch/function boundaries so their break/continue
//             scope is preserved.
//
//             Mirrors Nim closureiters.nim `transformBreakStmt`
//             (~/projects/nim/compiler/closureiters.nim:888) which walks
//             `finallyPathStack` to emit `nkGotoState`. Our 1-phase rewrite
//             is the simpler equivalent (no finally-chain support yet).
//
// Touched:    src/transform/lowering/generatorLower.ms
//             src/transform/lowering/asyncBridge.ms (ripple: StateCollector
//             initializer needs loopStack:[])

import { compileToC } from "../helpers";

test "bug031: async while with break does not emit bare break in dispatcher" {
	// Diagnostic: pre-fix codegen emitted a bare `break;` at the dispatcher
	// state-body indent (16 spaces deep inside the lifted stepper function),
	// which exits the outer `while (1)` dispatcher instead of transitioning
	// $state. Post-fix the break is rewritten to a state-goto block
	// (state-assign + bare `continue;`) so this exact substring vanishes.
	// Indentation here is stable across our codegen — if it shifts, this
	// test will surface that drift too.
	const src = `
async function loop(): Promise<void> {
	let i = 0;
	while (true) {
		await sleepAsync(0);
		i = i + 1;
		if (i === 3) break;
	}
}

function main(): void {
	loop();
}
`;
	const c = compileToC(src);
	assert c.ok;
	if (c.ok) {
		// State machine present.
		assert c.value.includes("dollarstate_");
		// Pre-fix bug shape: bare `break;` at state-body indent inside the
		// dispatcher (12 spaces for this source's nesting depth). Must NOT
		// appear after fix — break is rewritten to state-assign + continue.
		assert !c.value.includes("\n            break;\n          }\n");
	}
}

test "bug031: async for..of with break compiles" {
	// for..of is lowered to while BEFORE generatorLower, so break in for..of
	// hits the same fix path.
	const src = `
async function take(arr: number[], stopAt: number): Promise<number> {
	let sum = 0;
	for (const v of arr) {
		if (v === stopAt) break;
		sum = sum + v;
	}
	return sum;
}

function main(): void {
	const _ = take([1, 2, 3, 99, 4], 99);
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "bug031: async while with continue compiles" {
	const src = `
async function skip(arr: number[], skipVal: number): Promise<number> {
	let total = 0;
	let i = 0;
	while (i < arr.length) {
		const v = arr[i];
		i = i + 1;
		await sleepAsync(0);
		if (v === skipVal) continue;
		total = total + v;
	}
	return total;
}

function main(): void {
	const _ = skip([1, 2, 3, 4, 5], 3);
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "bug031: break inside inner non-yield while keeps bare break semantics" {
	// Edge case: break inside an INNER non-yield while inside an outer async
	// while-with-await must NOT be rewritten — the inner break targets the
	// inner while. rewriteLoopExits stops at nested WhileStmt to preserve this.
	const src = `
async function outerInner(matrix: number[][], target: number): Promise<number> {
	let found = -1;
	let r = 0;
	while (r < matrix.length) {
		await sleepAsync(0);
		const row = matrix[r];
		let c = 0;
		while (c < row.length) {
			if (row[c] === target) {
				found = r * 100 + c;
				break;
			}
			c = c + 1;
		}
		if (found >= 0) break;
		r = r + 1;
	}
	return found;
}

function main(): void {
	const _ = outerInner([[1, 2], [3, 4]], 3);
}
`;
	const c = compileToC(src);
	assert c.ok;
}
