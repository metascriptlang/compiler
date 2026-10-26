// @exit: 1
// @stdout: before
// @xfail(danger): --danger drops the conversion check, so the wrong class reads as the target there
// note: a checked conversion to a class the value is not stops the program on every backend, inside a `try` too: no `catch` sees it, `after` never prints, and the message names the target as written, `Box<number>`.
class Box<T> { v: T; constructor(v: T) { this.v = v; } }
class Other { n: number = 1; }

function make(): unknown { return new Other(); }

function main(): void {
	console.log("before");
	try {
		const b = make() as Box<number>;
		console.log("no error " + b.v.toString());
	} catch (e) {
		console.log("caught");
	}
	console.log("after");
}

main();
