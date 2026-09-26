// @exit: 1
// @xfail(raiser): the Raiser VM cannot evaluate super in a constructor ('cannot evaluate super at comptime: symbol kind is Class')
// @stdout: caught first boom
// note: an exception nobody catches is reported and then released before the program exits, as Nim's nimTestErrorFlag does; the ledger saw one Boom per uncaught raise alive at exit.

class Boom extends Error {
	constructor(message: string) { super(message); }
}

function catchOne(): string {
	let seen = "";
	try {
		throw new Boom("first " + "boom");
	} catch (e) {
		seen = "caught " + e.message;
	}
	return seen;
}

console.log(catchOne());
throw new Boom("second " + "boom");
