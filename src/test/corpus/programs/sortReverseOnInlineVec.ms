// @stdout: field 1,2,3,4|0|1,2,3
// @stdout: reversed 3,2,1|4,3,2,1
// @stdout: local 1,2,3|3,2,1|2.5
// @stdout: view 3|1
class Holder {
	a: Vec<int32> = [1, 2, 3, 4];
	c: Vec<int32> = [0];
	b: Vec<float64> = [3.0, 1.0, 2.0];
}

function verify(): void {
	const h = new Holder();
	h.b.sort();
	console.log(`field ${h.a.join(",")}|${h.c.join(",")}|${h.b.join(",")}`);
	h.b.reverse();
	h.a.sort((x: int32, y: int32): number => (y - x) as number);
	console.log(`reversed ${h.b.join(",")}|${h.a.join(",")}`);
	let v: Vec<float64> = [2.0, 3.0, 1.0];
	v.sort();
	const up = v.join(",");
	v.reverse();
	let w: Vec<float64> = [2.5];
	w.sort().length;
	console.log(`local ${up}|${v.join(",")}|${w.join(",")}`);
	const s = v.sort();
	console.log(`view ${s.length}|${s[0]}`);
}

verify();
