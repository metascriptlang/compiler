// @stdout: fin=b0f0f1b2f2 catch=outer0 nest=b0i0a0o0c1i1o1i2o2 alloc=0,2, log=406
// @xfail(raiser): the Raiser VM skips the update after a continue that leaves a try/finally (prints 'fin=b0f0b2f2f3' where C prints 'fin=b0f0f1b2f2')
class Box { v: int32; constructor(v: int32) { this.v = v; } }
function mk(v: int32): Box { return new Box(v); }

function finallySeesCounter(): string {
	let out = "";
	for (let i: int32 = 0; i < 3; i++) {
		try {
			if (i == 1) continue;
			out = out + "b" + i.toString();
		} finally {
			out = out + "f" + i.toString();
		}
	}
	return out;
}

function step(i: int32): int32 {
	if (i == 1) throw new Error("step");
	return i + 1;
}

function updateOutsideCatch(): string {
	let seen: int32 = 0;
	try {
		for (let i: int32 = 0; i < 3; i = step(i)) {
			try {
				continue;
			} catch {
				seen += 1;
				if (seen > 2) return "runaway";
			}
		}
		return "done";
	} catch {
		return `outer${seen}`;
	}
}

function nestedTry(): string {
	let out = "";
	let guard: int32 = 0;
	for (let i: int32 = 0; i < 3; i++) {
		guard += 1;
		if (guard > 20) return out + "HANG";
		try {
			try {
				if (i == 1) throw new Error("x");
				if (i == 2) continue;
				out = out + "b" + i.toString();
			} catch {
				out = out + "c" + i.toString();
				continue;
			} finally {
				out = out + "i" + i.toString();
			}
			out = out + "a" + i.toString();
		} finally {
			out = out + "o" + i.toString();
		}
	}
	return out;
}

let log: int32 = 0;

function allocInFinally(n: int32): int32 {
	for (let i: int32 = 0; i < 3; i++) {
		const b = mk(i);
		try {
			if (i == n) return i;
			if (i == 1) continue;
		} finally {
			const c = mk(i + b.v);
			try {
				log += c.v;
			} finally {
				log += 100;
			}
		}
	}
	return -1;
}

function allocRuns(): string {
	return `${allocInFinally(0)},${allocInFinally(2)},`;
}

console.log(`fin=${finallySeesCounter()} catch=${updateOutsideCatch()} nest=${nestedTry()} alloc=${allocRuns()} log=${log}`);
