// @stdout: generic caught boom
// @stdout: constructor caught boom
// @stdout: closure caught boom
// @stdout: resolve caught boom
// @stdout: after
// @stdout: ordered void middle 11
function boom(): void { throw new Error("boom"); }

function k<T>(x: T): void { console.log("k ran"); }

class Holder<T> {
	constructor(x: T) { console.log("constructor ran"); }
}

function callWith<T>(f: (x: T) => void, make: () => T): void {
	f(make());
}

try {
	k(boom());
} catch (e) {
	console.log(`generic caught ${(e as Error).message}`);
}
try {
	const h = new Holder<void>(boom());
	console.log("holder made");
} catch (e) {
	console.log(`constructor caught ${(e as Error).message}`);
}
try {
	callWith<void>((x: void): void => { console.log("closure ran"); }, boom);
} catch (e) {
	console.log(`closure caught ${(e as Error).message}`);
}
try {
	Promise.resolve(boom());
	console.log("resolved");
} catch (e) {
	console.log(`resolve caught ${(e as Error).message}`);
}
console.log("after");

struct OrderPair { x: int64; y: int64; }
let orderCounter: int64 = 0;

@noinline function firstPair(): OrderPair {
	const before = orderCounter;
	orderCounter += 1;
	return { x: before, y: 0 };
}

@noinline function bumpOrder(): void { orderCounter += 10; }
@noinline function takeMiddle(p: OrderPair, effect: void, n: int64): int64 { return p.x * 100 + n; }

@noinline function orderedMiddle(): int64 {
	orderCounter = 0;
	return takeMiddle(firstPair(), bumpOrder(), orderCounter);
}

console.log(`ordered void middle ${orderedMiddle()}`);
