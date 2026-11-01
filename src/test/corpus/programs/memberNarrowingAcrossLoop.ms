// @stdout: 1 2 3
class N { id: int32 = 0; }
class M { xs: Vec<N> | null = null; }
class O { m: M = new M(); }

function forCondition(m: M): int32 {
	if (m.xs != null) {
		let out: Vec<N> = [];
		for (let i = 0; i < m.xs.length; i += 1) out.push(new N());
		m.xs = out;
		return out.length;
	}
	return -1;
}

function whileCondition(m: M): int32 {
	if (m.xs != null) {
		let n = 0;
		while (n < m.xs.length) { n += 1; }
		return n;
	}
	return -1;
}

function deeper(o: O): int32 {
	if (o.m.xs != null) {
		let n = 0;
		while (n < o.m.xs.length) { n += 1; }
		return n;
	}
	return -1;
}

const one = new M();
let v1: Vec<N> = [];
v1.push(new N());
one.xs = v1;
const two = new M();
let v2: Vec<N> = [];
v2.push(new N());
v2.push(new N());
two.xs = v2;
const o = new O();
let v3: Vec<N> = [];
v3.push(new N());
v3.push(new N());
v3.push(new N());
o.m.xs = v3;
console.log(`${forCondition(one)} ${whileCondition(two)} ${deeper(o)}`);
