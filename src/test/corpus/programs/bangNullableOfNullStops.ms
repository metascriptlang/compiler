// @exit: 1
// @stdout: before 5 2
// @xfail(raiser): fatal VM errors use a different stderr report from C and JS
// note: postfix `!` on a value-carried `T | null` holding null stops; it used to read 0 (C, Raiser) or carry null on (JS).

struct Point { x: int32 }

struct Slot { count: int32 | null; at: Point | null }

function count(absent: boolean): int32 | null {
	if (absent) return null;
	return 4;
}

const full: Slot = { count: 2, at: { x: 2 } };
console.log(`before ${count(false)! + 1} ${full.at!.x}`);
const empty: Slot = { count: null, at: null };
console.log(`after ${empty.count! + count(true)!}`);
