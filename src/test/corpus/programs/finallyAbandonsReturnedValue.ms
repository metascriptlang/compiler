// @stdout: t0 t1 x x | b0 b1 x x | 0 1 -1 -1 | s0 s1 x x | n0 n1 x x
// note: a return whose finally raises or returns again hands its value to nobody, so the value is released there: a string and a class instance abandoned by a raise, a class instance replaced by the finally's own return, a struct returned from a loop inside a catch, and a string returned from an inner try nested in the raising one.

class Box { v: int32 = 0; }

struct Named { name: string; n: int32; }

function text(n: int32): string {
	try {
		return `t${n}`;
	} finally {
		if (n > 1) throw new Error("late");
	}
}

function raised(n: int32): Box {
	try {
		const b = new Box();
		b.v = n;
		return b;
	} finally {
		if (n > 1) throw new Error("late");
	}
}

function replaced(n: int32): Box {
	try {
		const b = new Box();
		b.v = n;
		return b;
	} finally {
		if (n > 1) {
			const c = new Box();
			c.v = -1;
			return c;
		}
	}
}

function fromCatch(n: int32): Named {
	try {
		throw new Error("early");
	} catch (e) {
		for (let i: int32 = 0; i < 3; i += 1) {
			if (i == 1) return { name: `s${n}`, n };
		}
		return { name: "none", n };
	} finally {
		if (n > 1) throw new Error("late");
	}
}

function nested(n: int32): string {
	try {
		try {
			return `n${n}`;
		} catch (e) {
			return "caught";
		}
	} finally {
		if (n > 1) throw new Error("late");
	}
}

const texts: string[] = [];
const raises: string[] = [];
const boxes: string[] = [];
const structs: string[] = [];
const inner: string[] = [];
for (let i: int32 = 0; i < 4; i += 1) {
	try { texts.push(text(i)); } catch (e) { texts.push("x"); }
	try { raises.push(`b${raised(i).v}`); } catch (e) { raises.push("x"); }
	boxes.push(`${replaced(i).v}`);
	try { structs.push(fromCatch(i).name); } catch (e) { structs.push("x"); }
	try { inner.push(nested(i)); } catch (e) { inner.push("x"); }
}
console.log(`${texts.join(" ")} | ${raises.join(" ")} | ${boxes.join(" ")} | ${structs.join(" ")} | ${inner.join(" ")}`);
