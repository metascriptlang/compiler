// A finally body is emitted once per way out of its try (return, break, continue, fall through),
// so a loop in it that C labels (a for with continue, a for-of over an inlined generator) is emitted
// several times in one function and every copy needs its own C label.
//
// @stdout: a:early
// @stdout: b:body02
// @stdout: c:02
// @stdout: d:0202
// @stdout: e:|
// @stdout: f:0202
// @stdout: g:early
// @stdout: h:body1
// @exit: 0

function viaReturn(n: int32): string {
	let s = "";
	try {
		if (n == 0) return "early";
		s += "body";
	} finally {
		for (let j: int32 = 0; j < 3; j += 1) {
			if (j == 1) continue;
			s += j.toString();
		}
	}
	return s;
}

function viaLoopJumps(mode: int32): string {
	let s = "";
	for (let i: int32 = 0; i < 2; i += 1) {
		try {
			if (mode == 0 && i == 0) break;
			if (mode == 1 && i == 0) continue;
		} finally {
			for (let j: int32 = 0; j < 3; j += 1) {
				if (j == 1) continue;
				s += j.toString();
			}
		}
	}
	return s;
}

function nested(n: int32): string {
	let s = "";
	try {
		try {
			if (n == 0) return s;
		} finally {
			for (let j: int32 = 0; j < 3; j += 1) {
				if (j == 1) continue;
				s += j.toString();
			}
		}
	} finally {
		for (let j: int32 = 0; j < 3; j += 1) {
			if (j == 1) continue;
			s += j.toString();
		}
	}
	return s;
}

function* gen(): Iterator<int32> {
	yield 1;
	yield 2;
	yield 3;
}

function inlinedGenerator(n: int32): string {
	let s = "";
	try {
		if (n == 0) return "early";
		s += "body";
	} finally {
		for (const v of gen()) {
			if (v == 2) break;
			s += v.toString();
		}
	}
	return s;
}

console.log("a:" + viaReturn(0));
console.log("b:" + viaReturn(1));
console.log("c:" + viaLoopJumps(0));
console.log("d:" + viaLoopJumps(1));
console.log("e:" + nested(0) + "|");
console.log("f:" + nested(1));
console.log("g:" + inlinedGenerator(0));
console.log("h:" + inlinedGenerator(1));
