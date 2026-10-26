// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
struct Res {
	id: int32;
	box: Box;
}

class Box {
	n: int32;
	constructor(n: int32) { this.n = n; }
}

struct Plain {
	id: int32;
}

let destroyed: int32 = 0;
let copied: int32 = 0;

function onDestroy(this x: Res): void {
	destroyed = destroyed * 10 + x.id;
}

function onCopy(this ref dest: Res, src: Res): void {
	copied += 1;
	dest.id = src.id;
	dest.box = src.box;
}

function make(id: int32): Res {
	return { id: id, box: new Box(id) };
}

function run(): void {
	const a = make(1);
	const b = a;
	console.log(copied);
	const p: Plain = { id: 9 };
	const q = p;
	console.log(q.id + b.box.n);
	{
		const c = make(2);
		console.log(c.id);
	}
	console.log(destroyed);
	console.log(a.id);
}

run();
console.log(destroyed);
console.log(copied);
