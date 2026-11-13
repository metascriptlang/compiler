// @stdout: head 1 n3
// @stdout: middle 2 n3n3
// @stdout: tail 1 n3
// @stdout: shrink 1 n3
// @stdout: reverse odd 3 n3
// @stdout: reverse even 4 n3n3
// @stdout: live n3n2n1 n2n1 n2 n1n2n3
// note: `splice`, `shrink` and `reverse` on an array of Unowned<T> drop or move its edges without reading them, so an edge whose target was destroyed does not stop the program; the live targets stay alive and readable.
class N { name: string; constructor(name: string) { this.name = name; } }
class H { ups: Unowned<N>[] = []; }
function mk(k: int32): N { return new N("n" + k.toString()); }

function pushTwoThatDie(h: H): void {
	const a = mk(1);
	const b = mk(2);
	h.ups.push(a);
	h.ups.push(b);
}

function head(keep: N): void {
	const h = new H();
	pushTwoThatDie(h);
	h.ups.push(keep);
	h.ups.splice(0, 2);
	console.log("head " + h.ups.length.toString() + " " + h.ups[0].name);
}

function middle(keep: N): void {
	const h = new H();
	h.ups.push(keep);
	pushTwoThatDie(h);
	h.ups.push(keep);
	h.ups.splice(1, 2);
	console.log("middle " + h.ups.length.toString() + " " + h.ups[0].name + h.ups[1].name);
}

function tail(keep: N): void {
	const h = new H();
	h.ups.push(keep);
	pushTwoThatDie(h);
	h.ups.splice(1, 2);
	console.log("tail " + h.ups.length.toString() + " " + h.ups[0].name);
}

function shrinks(keep: N): void {
	const h = new H();
	h.ups.push(keep);
	pushTwoThatDie(h);
	h.ups.shrink(1);
	console.log("shrink " + h.ups.length.toString() + " " + h.ups[0].name);
}

function reverseOdd(keep: N): void {
	const h = new H();
	pushTwoThatDie(h);
	h.ups.push(keep);
	h.ups.reverse();
	console.log("reverse odd " + h.ups.length.toString() + " " + h.ups[0].name);
}

function reverseEven(keep: N): void {
	const h = new H();
	pushTwoThatDie(h);
	h.ups.push(keep);
	h.ups.push(keep);
	h.ups.reverse();
	console.log("reverse even " + h.ups.length.toString() + " " + h.ups[0].name + h.ups[1].name);
}

function live(): void {
	const a = mk(1);
	const b = mk(2);
	const c = mk(3);
	const h = new H();
	h.ups.push(a);
	h.ups.push(b);
	h.ups.push(c);
	h.ups.reverse();
	const reversed = h.ups[0].name + h.ups[1].name + h.ups[2].name;
	h.ups.splice(0, 1);
	const spliced = h.ups[0].name + h.ups[1].name;
	h.ups.shrink(1);
	console.log("live " + reversed + " " + spliced + " " + h.ups[0].name + " " + a.name + b.name + c.name);
}

const keep = mk(3);
head(keep);
middle(keep);
tail(keep);
shrinks(keep);
reverseOdd(keep);
reverseEven(keep);
live();
