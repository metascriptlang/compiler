// @stdout: chain 8 | deep 4 | deep caught -1 | recur 14
// @stdout: finally ran
// @stdout: binary caught big 7 | nested caught big 8
// @stdout: ping caught seven | callback caught big 9 | dispatch caught square | plain 4 | ctor caught ctor | caught big 6 | after loop 3
// note: a call is checked for the error flag only when its routine can raise, and a statement is checked when any call in its value can raise; every raise here reaches its catch with nothing after it run, through calls that are not checked because they cannot raise.

function pure(n: int32): int32 { return n + 1; }
function chain(n: int32): int32 { return pure(n) * 2; }
function thrower(n: int32): int32 {
	if (n > 5) throw new Error("big " + String(n));
	return n;
}
function viaChain(n: int32): int32 {
	const v = thrower(n);
	return pure(v) + 0;
}
function deep(n: int32): int32 {
	const v = viaChain(n);
	return v - 1 + chain(0) - 2;
}
function caught(n: int32): int32 {
	try { return deep(n); } catch (e) { return -1; }
}
function recur(n: int32): int32 { return n <= 0 ? 0 : recur(n - 1) + pure(n); }
function ping(n: int32): int32 { return n <= 0 ? 0 : pong(n - 1); }
function pong(n: int32): int32 {
	if (n == 7) throw new Error("seven");
	return ping(n);
}
function callback(f: (x: int32) => int32): int32 {
	const r = f(9);
	return r + chain(1);
}
class Shape { area(): int32 { return 1; } }
class Square extends Shape { area(): int32 { throw new Error("square"); } }
class Point { x: int32 = 2; twice(): int32 { return this.x * 2; } }
function areaOf(s: Shape): int32 { return s.area(); }
class Strict {
	n: int32;
	constructor(n: int32) {
		if (n < 0) throw new Error("ctor");
		this.n = n;
	}
}
function build(n: int32): int32 {
	const s = new Strict(n);
	return s.n + chain(0);
}
function withFinally(n: int32): int32 {
	try { return thrower(n); } finally { console.log("finally ran"); }
}
function binaryValue(n: int32): int32 {
	const y = pure(1) + thrower(n);
	console.log("after binary");
	return y;
}
function nestedArg(n: int32): int32 {
	console.log(`nested ${thrower(n)}`);
	console.log("after nested");
	return 1;
}
function sumLoop(limit: int32): int32 {
	let total: int32 = 0;
	for (let i: int32 = 0; i < limit; i += 1) total += pure(i) - i;
	return total;
}

console.log(`chain ${chain(3)} | deep ${caught(4)} | deep caught ${caught(9)} | recur ${recur(4)}`);
let pinged = "";
try { ping(10); pinged = "not reached"; } catch (e) { pinged = "caught " + (e as Error).message; }
let called = "";
try { callback(thrower); called = "not reached"; } catch (e) { called = "caught " + (e as Error).message; }
let dispatched = "";
try { areaOf(new Square()); dispatched = "not reached"; } catch (e) { dispatched = "caught " + (e as Error).message; }
let constructed = "";
try { build(-1); constructed = "not reached"; } catch (e) { constructed = "caught " + (e as Error).message; }
let finished = "";
try { withFinally(6); finished = "not reached"; } catch (e) { finished = "caught " + (e as Error).message; }
let binary = "";
try { binaryValue(7); binary = "not reached"; } catch (e) { binary = "caught " + (e as Error).message; }
let nested = "";
try { nestedArg(8); nested = "not reached"; } catch (e) { nested = "caught " + (e as Error).message; }
console.log(`binary ${binary} | nested ${nested}`);
console.log(`ping ${pinged} | callback ${called} | dispatch ${dispatched} | plain ${new Point().twice()} | ctor ${constructed} | ${finished} | after loop ${sumLoop(3)}`);
