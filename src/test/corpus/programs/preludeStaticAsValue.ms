// @stdout: apply(Math.floor)=3
// @stdout: apply(Math.abs)=2.5
// @stdout: apply(Math.trunc)=-1
// @stdout: stored Math.floor: 2
// @stdout: Number.isInteger as value: true false
// @stdout: stored Math.pow: 1024
// @stdout: calls: 3 2.5 true
// @xfail(raiser): the Raiser VM reads an extern routine passed or stored as a value as 0 (Math.floor, Math.abs, Math.trunc, Math.pow print 0); Number.isInteger, an MS routine there, passes

function apply(f: (x: number) => number, x: number): number {
	return f(x);
}

function check(f: (x: number) => boolean, x: number): boolean {
	return f(x);
}

console.log(`apply(Math.floor)=${apply(Math.floor, 3.7)}`);
console.log(`apply(Math.abs)=${apply(Math.abs, -2.5)}`);
console.log(`apply(Math.trunc)=${apply(Math.trunc, -1.9)}`);

const down = Math.floor;
console.log(`stored Math.floor: ${down(2.5)}`);

console.log(`Number.isInteger as value: ${check(Number.isInteger, 4)} ${check(Number.isInteger, 4.5)}`);

const power = Math.pow;
console.log(`stored Math.pow: ${power(2, 10)}`);

console.log(`calls: ${Math.floor(3.7)} ${Math.abs(-2.5)} ${Number.isInteger(8)}`);
