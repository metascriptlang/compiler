// @skip-js: C-only by design: onDestroy counts the destroys the DRC makes; JS frees nothing
// @stdout: live n2 n1n2n3
// @stdout: dead left 0 destroyed 2
// @stdout: hook left 0 destroyed 1
// note: `length = 0` on an array of Unowned<T> gives up each element on its Unowned count: live targets stay alive, edges to destroyed targets go without a read, and a target whose onDestroy empties the array that points at it is destroyed once.
class N { name: string; constructor(name: string) { this.name = name; } }
class H { ups: Unowned<N>[] = []; }
function mk(k: int32): N { return new N("n" + k.toString()); }

let destroyed = 0;
let emptiedOnDestroy: H | null = null;
function onDestroy(this n: N): void {
	destroyed += 1;
	const h = emptiedOnDestroy;
	if (h != null) h.ups.length = 0;
}

function live(): void {
	const a = mk(1);
	const b = mk(2);
	const c = mk(3);
	const h = new H();
	h.ups.push(a);
	h.ups.push(b);
	h.ups.push(c);
	h.ups.length = 0;
	h.ups.push(b);
	console.log("live " + h.ups[0].name + " " + a.name + b.name + c.name);
}

function fill(h: H): void {
	const a = mk(4);
	const b = mk(5);
	h.ups.push(a);
	h.ups.push(b);
}

function dead(): void {
	const before = destroyed;
	const h = new H();
	fill(h);
	h.ups.length = 0;
	console.log("dead left " + h.ups.length.toString() + " destroyed " + (destroyed - before).toString());
}

function fillOne(h: H): void {
	const a = mk(6);
	h.ups.push(a);
}

function hook(): void {
	const before = destroyed;
	const h = new H();
	emptiedOnDestroy = h;
	fillOne(h);
	emptiedOnDestroy = null;
	console.log("hook left " + h.ups.length.toString() + " destroyed " + (destroyed - before).toString());
}

live();
dead();
hook();
