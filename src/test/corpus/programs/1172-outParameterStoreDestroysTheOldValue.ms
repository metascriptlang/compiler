// @stdout: x7!
// @stdout: orig! 1
// @stdout: 1
// @stdout: fresh 0
// @stdout: out parameter stores done

function fill(out a: string, b: string): void { a = b + "!"; }
function fillArr(out a: int32[], b: int32[]): void { a = [b.length as int32]; }
class Holder { name: string = "orig"; tags: int32[] = []; }
function fillHolder(out h: Holder, name: string): void { h = new Holder(); h.name = name; }

function run(n: int32): void {
	let s = "x" + n.toString();
	fill(out s, s);
	console.log(s);
	const h = new Holder();
	fill(out h.name, h.name);
	fillArr(out h.tags, [1, 2, 3]);
	console.log(h.name + " " + h.tags.length.toString());
	let xs: int32[] = [n];
	fillArr(out xs, xs);
	console.log(xs[0].toString());
	let held = new Holder();
	fillHolder(out held, "fresh");
	console.log(held.name + " " + held.tags.length.toString());
}

run(7);
console.log("out parameter stores done");
