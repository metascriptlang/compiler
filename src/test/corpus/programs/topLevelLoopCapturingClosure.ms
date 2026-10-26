// @stdout: do-while 2
// @stdout: while-false 2
// @stdout: nested 6
// @stdout: switch 3
// @stdout: chain 15

let a: int32 = 0;
do {
	let seen: int32 = 0;
	const bump = (): void => { seen = seen + 1; };
	bump();
	bump();
	a = seen;
} while (a < 0);
console.log(`do-while ${a}`);

let b: int32 = 0;
do {
	let seen: int32 = 0;
	const bump = (): void => { seen = seen + 1; };
	bump();
	bump();
	b = seen;
} while (false);
console.log(`while-false ${b}`);

let c: int32 = 0;
do {
	let outer: int32 = 0;
	for (let i: int32 = 0; i < 2; i++) {
		let inner: int32 = 0;
		const add = (): void => { inner = inner + 1; outer = outer + inner; };
		add();
		add();
	}
	c = outer;
} while (c < 0);
console.log(`nested ${c}`);

const k: int32 = 1;
switch (k) {
	case 1: {
		let hits: int32 = 0;
		const hit = (): void => { hits = hits + 1; };
		hit();
		hit();
		hit();
		console.log(`switch ${hits}`);
		break;
	}
	default: console.log("switch other");
}

let total: int32 = 0;
for (const x of [1, 2].values().map((v: int32): int32 => v + 1)) {
	let acc: int32 = 0;
	const f = (): void => { acc += x; };
	f();
	f();
	total += acc + x;
}
console.log(`chain ${total}`);
