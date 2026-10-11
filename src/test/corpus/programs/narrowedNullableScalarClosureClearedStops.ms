// @exit: 1
// @stdout: member 'int32' is not accessible for type 'int32 | null' using 'null'
// @xfail(raiser): fatal VM errors use a different stderr report from C and JS
// note: a narrowed `int32 | null` field read after a closure cleared it stops; it used to read 0 on C, JS and the Raiser.

class Box { y: int32 | null = 2; }

function each(f: () => void): void { f(); }

function run(): void {
	const b = new Box();
	if (b.y != null) {
		console.log(`before ${b.y + 1}`);
		each((): void => { b.y = null; });
		console.log(`after ${b.y + 1}`);
	}
}

run();
