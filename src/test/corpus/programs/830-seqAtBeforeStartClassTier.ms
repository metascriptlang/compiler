// @exit: 1
// @stdout: index -3 out of bounds (length 2)
// @skip-js: node reports the uncaught index error with its own stack trace; exit code matches but the text differs (sibling of 721)
class Cell { v: int32 = 0; }

function run(): void {
	const a: Cell[] = [];
	for (let i: int32 = 1; i <= 2; i++) {
		const c = new Cell();
		c.v = i * 10;
		a.push(c);
	}
	console.log(`first=${a.at(-2).v} len=${a.length}`);
	console.log(`unreachable ${a.at(-3).v}`);
}

run();
