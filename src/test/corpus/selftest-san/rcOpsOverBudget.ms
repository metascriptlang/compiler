// @selftest-red rc ops
// @maxrcops: 0
class Box {
	n: int32 = 0;
}

function keep(b: Box): Box {
	return b;
}

const a = new Box();
const b = keep(a);
const c = b;
console.log(a.n + c.n);
