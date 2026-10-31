// @stdout: same=true/true len=4 box=true n=3 nested=true/3 generic=true/3 local=3 param=4 loop=300000
// note: a Borrow<T> returned from a class or array first parameter is that reference itself, so the caller reads the object the callee was given, not the callee's parameter slot, under --danger as under the debug build.

class Box { n: int32 = 3; }

function mine(this arr: number[]): Borrow<number[]> { arr.push(1.0); return arr; }
function self(this b: Box): Borrow<Box> { return b; }
function forward(this b: Box): Borrow<Box> { return b.self(); }
function same<T>(this x: T): Borrow<T> { return x; }
function readN(b: Borrow<Box>): int32 { return b.n + 1; }

function main(): void {
	const a: number[] = [2.0];
	const sameArr = a.mine() === a;
	const sameAgain = a.mine() === a;
	const kept = a.mine();
	const bx = new Box();
	const sb = bx.self();
	const v: Borrow<Box> = bx;
	const nested = bx.forward();
	const generic = bx.same();
	let loop = 0;
	for (let i = 0; i < 100000; i += 1) {
		if (bx.self() === bx) loop += 1;
		if (bx.forward() === bx) loop += 1;
		if (bx.same() === bx) loop += 1;
	}
	console.log(`same=${sameArr}/${sameAgain} len=${kept.length} box=${bx.self() === bx} n=${sb.n} nested=${nested === bx}/${nested.n} generic=${generic === bx}/${generic.n} local=${v.n} param=${readN(bx)} loop=${loop}`);
}

main();
