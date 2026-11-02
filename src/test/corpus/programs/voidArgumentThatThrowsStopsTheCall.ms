// @stdout: generic caught boom
// @stdout: constructor caught boom
// @stdout: closure caught boom
// @stdout: resolve caught boom
// @stdout: after
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
