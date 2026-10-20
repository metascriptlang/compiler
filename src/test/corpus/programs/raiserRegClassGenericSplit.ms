// @stdout: 7 ab 6
// note: one generic body holds its source register in the word class at number and in the ref class at string, and a closure made in a loop inside a method reads its loop variable and this.

function hold<T>(x: T, n: number): T {
	let r = x;
	for (let i = 0; i < n; i++) { r = x; }
	return r;
}

class Counter {
	n: number = 1;
	run(): number {
		let t: number = 0;
		for (let i = 0; i < 3; i++) {
			const f = (): number => i + this.n;
			t += f();
		}
		return t;
	}
}

console.log(`${hold(7, 2)} ${hold("ab", 2)} ${new Counter().run()}`);
