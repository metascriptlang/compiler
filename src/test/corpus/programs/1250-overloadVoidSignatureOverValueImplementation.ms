// @stdout: 3
let counter = 0;
function note(s: string): void;
function note(s: number): void;
function note(s: string | number): number { counter += 1; return counter; }

class Log {
	n = 0;
	add(s: string): void;
	add(s: number): void;
	add(s: string | number): number { this.n += 1; return this.n; }
}

note("a");
note(2);
const l = new Log();
l.add("x");
console.log(counter + l.n);
