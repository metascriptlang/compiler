// @stdout: caught=60 kept=19 last=7 s=box--3
// note: a value returned through a finally or a defer that raises reaches the caller, which destroys it; a finally that does not raise still returns the value.

class Box {
	v: int32;
	constructor(v: int32) {
		this.v = v;
	}
}

function check(i: int32): void {
	if (i >= 0) throw new Error("chk");
}

function viaFinally(i: int32): Box {
	try {
		return new Box(i);
	} finally {
		check(i);
	}
}

function viaThrowInFinally(i: int32): Box {
	try {
		return new Box(i);
	} finally {
		if (i >= 0) throw new Error("fin");
	}
}

function viaDefer(i: int32): Box {
	defer {
		check(i);
	}
	return new Box(i);
}

function viaNested(i: int32): Box {
	try {
		try {
			return new Box(i);
		} finally {
			check(i - 100);
		}
	} finally {
		check(i);
	}
}

function viaString(i: int32): string {
	try {
		return `box-${i}`;
	} finally {
		check(i);
	}
}

function keeps(i: int32): Box {
	try {
		return new Box(i);
	} finally {
		check(-1);
	}
}

let caught = 0;
let kept = 0;
let last = 0;
for (let i = 0; i < 10; i += 1) {
	try { viaFinally(i); } catch (e) { caught += 1; }
	try { const b = viaThrowInFinally(i); last = b.v; } catch (e) { caught += 1; }
	try { viaDefer(i); } catch (e) { caught += 1; }
	try { last = viaNested(i).v; } catch (e) { caught += 1; }
	try { viaString(i); } catch (e) { caught += 1; }
	try { console.log(viaString(i)); } catch (e) { caught += 1; }
	kept += keeps(i).v > 0 ? 2 : 1;
	last = keeps(7).v;
}
console.log(`caught=${caught} kept=${kept} last=${last} s=${viaString(-3)}`);
