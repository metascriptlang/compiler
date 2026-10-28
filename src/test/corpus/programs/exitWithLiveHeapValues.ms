// @stdout: ok 5 2
// @exit: 7
// note: process.exit ends the program with no destructors run, so a string and an array still held by a module global and by a live local are not leaks.

let head = "";
head = `ok ${5}`;
const xs: int32[] = [1, 2];

function stop(): void {
	const local = head + " " + xs.length.toString();
	console.log(local);
	process.exit(7);
}

stop();
