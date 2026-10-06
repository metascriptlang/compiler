// @exit: 1
// @stdout: before 3
// @xfail(danger): --danger drops the tag test, so the read of the other member is undefined behaviour
// @xfail(raiser): the Raiser VM does not test union conversions

struct Point { x: int32 }

function pointOrText(k: int32): Point | string {
	if (k == 0) { const p: Point = { x: 3 }; return p; }
	return "s";
}

function asPoint(k: int32): Point { return pointOrText(k) as Point; }

console.log(`before ${asPoint(0).x}`);
console.log(`after ${asPoint(1).x}`);
