// @stdout: loop=12 num=9 fn=2
// note: a class held in a union beside a function is released by the held value's kind, once per loop pass, so nothing stays live at exit. Second axis: the other member is a number, and the held member is the function.
class Boxed {
	message: string;
	constructor(m: string) { this.message = m; }
}
type ClassFn = Boxed | ((p: Boxed) => Boxed);
type ClassNum = Boxed | number;

function unbox(u: ClassFn): Boxed {
	return u as Boxed;
}

function run(): string {
	let acc = 0;
	let num = 0;
	let calls = 0;
	for (let i = 0; i < 3; i += 1) {
		const t: ClassFn = new Boxed("loop");
		acc += unbox(t).message.length;
		const n: ClassNum = new Boxed("num");
		num += (n as Boxed).message.length;
	}
	const f: ClassFn = (p: Boxed): Boxed => new Boxed(p.message + "!");
	if (typeof f === "function") calls += f(new Boxed("a")).message.length;
	return "loop=" + acc.toString() + " num=" + num.toString() + " fn=" + calls.toString();
}

console.log(run());
