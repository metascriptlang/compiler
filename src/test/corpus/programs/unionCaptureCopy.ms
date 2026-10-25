// @stdout: closure=true,false|method=true,false|array=2,2|three=true|nested=true|field=2

function text(s: string): string | number { return s + "b"; }
function flag(s: string): string | number | boolean { return s + "c"; }

function viaClosure(u: string | number, v: string | number): boolean {
	const test = (): boolean => u == v;
	return test();
}

class Holder {
	same(other: string | number, third: string | number): boolean {
		const test = (): boolean => other == third;
		return test();
	}
}

function viaArray(u: string | number): number {
	const x = u;
	const arr: (string | number)[] = [];
	arr.push(x);
	arr.push(x);
	return arr.length;
}

function viaThree(u: string | number | boolean): boolean {
	const test = (): boolean => u == u;
	return test();
}

function viaNested(u: string | number): boolean {
	const outer = (): boolean => {
		const inner = (): boolean => u == u;
		return inner();
	};
	return outer();
}

interface Cell { v: string | number; }
function viaField(u: string | number): number {
	const a: Cell = { v: u };
	const b: Cell = { v: u };
	return a.v == b.v ? 2 : 0;
}

const a = text("a");
const f = flag("a");
const h = new Holder();
console.log(
	"closure=" + viaClosure(a, a) + "," + viaClosure(a, text("x"))
	+ "|method=" + h.same(a, a) + "," + h.same(a, text("x"))
	+ "|array=" + viaArray(a) + "," + viaArray(a)
	+ "|three=" + viaThree(f)
	+ "|nested=" + viaNested(a)
	+ "|field=" + viaField(a),
);
