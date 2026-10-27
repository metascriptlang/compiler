// @stdout: ret 5 break 1 ret-string 6 ret-nested 7
// note: a return or break inside a finally entered by a raise drops that exception and still delivers its own value, though the exception's destroy routine runs in the middle of the jump.

function boom(m: string): void { throw new Error(m); }
function boomString(m: string): void { throw m; }

function retInFinally(): int32 {
	try { boom("lost"); } finally { return 5; }
	return 0;
}
function breakInFinally(): int32 {
	let n: int32 = 0;
	while (n < 3) {
		n += 1;
		try { boom("lost in loop"); } finally { break; }
	}
	return n;
}
function retStringInFinally(): int32 {
	try { boomString("lost"); } finally { return 6; }
	return 0;
}
let fins: int32 = 0;
function retNested(): int32 {
	try {
		try { boom("inner"); } finally { return 7; }
	} finally {
		fins += 1;
	}
	return 0;
}

const nested = retNested();
console.log(`ret ${retInFinally()} break ${breakInFinally()} ret-string ${retStringInFinally()} ret-nested ${nested}`);
