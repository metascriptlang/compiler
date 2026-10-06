// @exit: 1
// @stdout: before 3
// @xfail(danger): --danger drops the union member check
// @xfail(raiser): fatal VM errors use a different stderr report from C and JS

struct Point { x: int32 }
struct Other { y: int32 }

function pick(k: int32): Point | Other {
	if (k == 0) { const p: Point = { x: 3 }; return p; }
	const q: Other = { y: 4 };
	return q;
}

console.log("before " + (pick(0) as Point).x.toString());
try {
	const p = pick(1) as Point;
	console.log("wrong " + p.x.toString());
} catch (e) {
	console.log("caught");
}
console.log("after");
