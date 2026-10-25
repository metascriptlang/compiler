// @stdout: 87096|87096|87096|87096|87096|87096|87096|87096|87096|87096
// A `@computedGoto;` loop whose integer index of a Span is carried as a pointer under --danger runs
// every index shape the pass rewrites (read at an offset, step, jump to a new place, read of the index
// itself) and each shape it leaves alone, and prints what the array-indexed reference prints: the C
// lanes, danger, JS and Raiser agree only if the rewrite changed nothing a program can see.

enum Op { Step, Back, Loop, Stop }

const bytes: int64[] = [0, 0, 1, 2, 0, 3];
const values: int64[] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];
const narrowBytes: int32[] = [0, 0, 1, 2, 0, 3];
const narrowValues: int32[] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];

function reference(code: int64[], vals: int64[], count: int64): int64 {
	let pc: int64 = 0;
	let vp: int64 = 0;
	let acc: int64 = 0;
	let cnt: int64 = count;
	while (true) {
		const op = (code[pc] & 0xff) as Op;
		pc += 1;
		switch (op) {
			case Op.Step: { acc += vals[vp] + vals[vp + 1]; vp += 2; break; }
			case Op.Back: { acc += vals[vp - 1]; vp -= 1; break; }
			case Op.Loop: { const target = code[pc]; cnt -= 1; if (cnt > 0) { pc = target; } else { pc += 1; } break; }
			case Op.Stop: return acc * 1000 + vp * 10 + pc;
		}
	}
}

function twoSpans(code: Span<int64>, vals: Span<int64>, count: int64): int64 {
	let pc: int64 = 0;
	let vp: int64 = 0;
	let acc: int64 = 0;
	let cnt: int64 = count;
	while (true) {
		@computedGoto;
		const op = (code[pc] & 0xff) as Op;
		pc += 1;
		switch (op) {
			case Op.Step: { acc += vals[vp] + vals[vp + 1]; vp += 2; break; }
			case Op.Back: { acc += vals[vp - 1]; vp -= 1; break; }
			case Op.Loop: { const target = code[pc]; cnt -= 1; if (cnt > 0) { pc = target; } else { pc += 1; } break; }
			case Op.Stop: return acc * 1000 + vp * 10 + pc;
		}
	}
}

function narrowIndex(code: Span<int32>, vals: Span<int32>, count: int32): int32 {
	let pc: int32 = 0;
	let vp: int32 = 0;
	let acc: int32 = 0;
	let cnt: int32 = count;
	while (true) {
		@computedGoto;
		const op = (code[pc] & 0xff) as Op;
		pc += 1;
		switch (op) {
			case Op.Step: { acc += vals[vp] + vals[vp + 1]; vp += 2; break; }
			case Op.Back: { acc += vals[vp - 1]; vp -= 1; break; }
			case Op.Loop: { const target = code[pc]; cnt -= 1; if (cnt > 0) { pc = target; } else { pc += 1; } break; }
			case Op.Stop: return acc * 1000 + vp * 10 + pc;
		}
	}
}

function localViews(code: int64[], vals: int64[], count: int64): int64 {
	const cv: Span<int64> = code;
	const vv: Span<int64> = vals;
	let pc: int64 = 0;
	let vp: int64 = 0;
	let acc: int64 = 0;
	let cnt: int64 = count;
	while (true) {
		@computedGoto;
		const op = (cv[pc] & 0xff) as Op;
		pc += 1;
		switch (op) {
			case Op.Step: { acc += vv[vp] + vv[vp + 1]; vp += 2; break; }
			case Op.Back: { acc += vv[vp - 1]; vp -= 1; break; }
			case Op.Loop: { const target = cv[pc]; cnt -= 1; if (cnt > 0) { pc = target; } else { pc += 1; } break; }
			case Op.Stop: return acc * 1000 + vp * 10 + pc;
		}
	}
}

function indexParameters(code: Span<int64>, vals: Span<int64>, pc0: int64, vp0: int64, count: int64): int64 {
	let acc: int64 = 0;
	let cnt: int64 = count;
	let pc = pc0;
	let vp = vp0;
	while (true) {
		@computedGoto;
		const op = (code[pc] & 0xff) as Op;
		pc += 1;
		switch (op) {
			case Op.Step: { acc += vals[vp] + vals[vp + 1]; vp += 2; break; }
			case Op.Back: { acc += vals[vp - 1]; vp -= 1; break; }
			case Op.Loop: { const target = code[pc]; cnt -= 1; if (cnt > 0) { pc = target; } else { pc += 1; } break; }
			case Op.Stop: return acc * 1000 + vp * 10 + pc;
		}
	}
}

function startAtParameter(code: Span<int64>, vals: Span<int64>, vp: int64, count: int64): int64 {
	let pc: int64 = 0;
	let acc: int64 = 0;
	let cnt: int64 = count;
	while (true) {
		@computedGoto;
		const op = (code[pc] & 0xff) as Op;
		pc += 1;
		switch (op) {
			case Op.Step: { acc += vals[vp] + vals[vp + 1]; vp += 2; break; }
			case Op.Back: { acc += vals[vp - 1]; vp -= 1; break; }
			case Op.Loop: { const target = code[pc]; cnt -= 1; if (cnt > 0) { pc = target; } else { pc += 1; } break; }
			case Op.Stop: return acc * 1000 + vp * 10 + pc;
		}
	}
}

function sharedIndex(code: Span<int64>, vals: Span<int64>, count: int64): int64 {
	let pc: int64 = 0;
	let vp: int64 = 0;
	let acc: int64 = 0;
	let cnt: int64 = count;
	while (true) {
		@computedGoto;
		const op = (code[pc] & 0xff) as Op;
		pc += 1;
		switch (op) {
			case Op.Step: { acc += vals[vp] + vals[vp + 1] + vals[pc] * 0; vp += 2; break; }
			case Op.Back: { acc += vals[vp - 1]; vp -= 1; break; }
			case Op.Loop: { const target = code[pc]; cnt -= 1; if (cnt > 0) { pc = target; } else { pc += 1; } break; }
			case Op.Stop: return acc * 1000 + vp * 10 + pc;
		}
	}
}

function scaledUpdate(code: Span<int64>, vals: Span<int64>, count: int64): int64 {
	let pc: int64 = 0;
	let vp: int64 = 0;
	let acc: int64 = 0;
	let cnt: int64 = count;
	while (true) {
		@computedGoto;
		const op = (code[pc] & 0xff) as Op;
		pc += 1;
		switch (op) {
			case Op.Step: { acc += vals[vp] + vals[vp + 1]; vp += 1; vp += 1; vp *= 1; break; }
			case Op.Back: { acc += vals[vp - 1]; vp -= 1; break; }
			case Op.Loop: { const target = code[pc]; cnt -= 1; if (cnt > 0) { pc = target; } else { pc += 1; } break; }
			case Op.Stop: return acc * 1000 + vp * 10 + pc;
		}
	}
}

function bump(ref n: int64): void { n += 0; }

function addressTaken(code: Span<int64>, vals: Span<int64>, count: int64): int64 {
	let pc: int64 = 0;
	let vp: int64 = 0;
	let acc: int64 = 0;
	let cnt: int64 = count;
	while (true) {
		@computedGoto;
		const op = (code[pc] & 0xff) as Op;
		pc += 1;
		switch (op) {
			case Op.Step: { acc += vals[vp] + vals[vp + 1]; vp += 2; bump(vp); break; }
			case Op.Back: { acc += vals[vp - 1]; vp -= 1; break; }
			case Op.Loop: { const target = code[pc]; cnt -= 1; if (cnt > 0) { pc = target; } else { pc += 1; } break; }
			case Op.Stop: return acc * 1000 + vp * 10 + pc;
		}
	}
}

function capturedIndex(code: Span<int64>, vals: Span<int64>, count: int64): int64 {
	let pc: int64 = 0;
	let vp: int64 = 0;
	let acc: int64 = 0;
	let cnt: int64 = count;
	const where = (): int64 => vp;
	while (true) {
		@computedGoto;
		const op = (code[pc] & 0xff) as Op;
		pc += 1;
		switch (op) {
			case Op.Step: { acc += vals[vp] + vals[vp + 1]; vp += 2; break; }
			case Op.Back: { acc += vals[vp - 1]; vp -= 1; break; }
			case Op.Loop: { const target = code[pc]; cnt -= 1; if (cnt > 0) { pc = target; } else { pc += 1; } break; }
			case Op.Stop: return acc * 1000 + where() * 10 + pc;
		}
	}
}

const results: string[] = [];
results.push(reference(bytes, values, 3).toString());
results.push(twoSpans(bytes, values, 3).toString());
results.push(narrowIndex(narrowBytes, narrowValues, 3).toString());
results.push(localViews(bytes, values, 3).toString());
results.push(indexParameters(bytes, values, 0, 0, 3).toString());
results.push(startAtParameter(bytes, values, 0, 3).toString());
results.push(sharedIndex(bytes, values, 3).toString());
results.push(scaledUpdate(bytes, values, 3).toString());
results.push(addressTaken(bytes, values, 3).toString());
results.push(capturedIndex(bytes, values, 3).toString());
console.log(results.join("|"));
