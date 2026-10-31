// @stdout: 2.5 3 -1 2.5 3 2.5 3
// @stdout: 2.5 3 2.5 3 2.5
type In = string | int32 | float64;
type Num = int32 | float64;

class Box {
	n: float64 = 0;
}

function narrowed(data: In): float64 {
	if (typeof data == "string") return -1;
	const x: float64 = data;
	return x;
}
function viaReturn(d: Num): float64 { return d; }
function takes(v: float64): float64 { return v; }
function viaArgument(d: Num): float64 { return takes(d); }
function viaField(d: Num): float64 {
	const b = new Box();
	b.n = d;
	return b.n;
}
function viaAssign(d: Num): float64 {
	let v: float64 = 0;
	v = d;
	return v;
}

console.log(narrowed(2.5), narrowed(3), narrowed("s"), viaReturn(2.5), viaReturn(3), viaArgument(2.5), viaArgument(3));
console.log(viaField(2.5), viaField(3), viaAssign(2.5), viaAssign(3), narrowed(2.5));
