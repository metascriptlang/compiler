// @stdout: frame-write -1 -1 100 101
// @stdout: closure-write 0 6 0 6 0 6
// @stdout: loop-variable 0 2 4
// @stdout: text i0 i0bc i1 i1bc i0bc i1bc
// @stdout: while 0 10 101 111
// @stdout: for-of 1 11 2 12
// @stdout: nested -1 -1 -1 -1 25 26 35 36
// @stdout: last-run 0 42
// @stdout: async-closure-write 666
// @stdout: async-write-after 105 105 105
// @stdout: async-loop-variable 0 2 4
// note: a closure made inside a loop of a generator or an async function shares that iteration's binding with the loop body: a write after the yield or await is seen by the closure, a write by the closure is seen by the body, and each iteration keeps its own binding. Before the fix C gave such a closure a copy of the binding taken when it was made, so a write on either side was lost.

function drain(g: Iterator<int32>): string {
	let out = "";
	let r = g.next();
	while (!r.done) {
		out = out + " " + String(r.value);
		r = g.next();
	}
	return out;
}

function drainText(g: Iterator<string>): string {
	let out = "";
	let r = g.next();
	while (!r.done) {
		out = out + " " + r.value;
		r = g.next();
	}
	return out;
}

function* frameWrite(n: int32): Iterator<int32> {
	const fs: (() => int32)[] = [];
	for (let i: int32 = 0; i < n; i++) {
		let local = i;
		fs.push((): int32 => local);
		yield -1;
		local = local + 100;
	}
	for (const f of fs) { yield f(); }
}

function* closureWrite(): Iterator<int32> {
	for (let i: int32 = 0; i < 3; i++) {
		let local: int32 = 5;
		const bump = (): void => { local += 1; };
		yield 0;
		bump();
		yield local;
	}
}

function* loopVariable(): Iterator<int32> {
	for (let i: int32 = 0; i < 6; i++) {
		const skip = (): void => { i += 1; };
		yield i;
		skip();
	}
}

function* text(): Iterator<string> {
	const fs: (() => string)[] = [];
	for (let i: int32 = 0; i < 2; i++) {
		let s = "i" + String(i);
		const app = (): void => { s = s + "b"; };
		yield s;
		app();
		s = s + "c";
		fs.push((): string => s);
		yield s;
	}
	for (const f of fs) { yield f(); }
}

function* whileLoop(): Iterator<int32> {
	const fs: (() => int32)[] = [];
	let i: int32 = 0;
	while (i < 2) {
		let n: int32 = i * 10;
		const inc = (): void => { n += 1; };
		yield n;
		inc();
		fs.push((): int32 => n);
		n += 100;
		i++;
	}
	for (const f of fs) { yield f(); }
}

function* forOf(): Iterator<int32> {
	const xs: int32[] = [1, 2];
	for (const x of xs) {
		let acc: int32 = x;
		const add = (): void => { acc += 10; };
		yield acc;
		add();
		yield acc;
	}
}

function* nested(): Iterator<int32> {
	const fs: (() => int32)[] = [];
	for (let i: int32 = 0; i < 2; i++) {
		let a: int32 = i;
		for (let j: int32 = 0; j < 2; j++) {
			let b: int32 = j;
			fs.push((): int32 => a * 10 + b);
			yield -1;
			a += 1;
			b += 5;
		}
	}
	for (const f of fs) { yield f(); }
}

let sink: int32 = 0;

function* lastRun(seed: int32): Iterator<int32> {
	yield 0;
	const n = seed + 1;
	const f = (): int32 => n;
	sink = f();
}

async function tick(): Promise<int32> {
	return 1;
}

async function asyncClosureWrite(): Promise<string> {
	let out = "";
	for (let i: int32 = 0; i < 3; i++) {
		let local: int32 = 5;
		const bump = (): void => { local += 1; };
		await tick();
		bump();
		out = out + String(local);
	}
	return out;
}

async function asyncWriteAfter(): Promise<string> {
	const fs: (() => int32)[] = [];
	for (let i: int32 = 0; i < 3; i++) {
		let local: int32 = 5;
		fs.push((): int32 => local);
		await tick();
		local += 100;
	}
	let out = "";
	for (const f of fs) { out = out + " " + String(f()); }
	return out;
}

async function asyncLoopVariable(): Promise<string> {
	let out = "";
	for (let i: int32 = 0; i < 6; i++) {
		const skip = (): void => { i += 1; };
		out = out + " " + String(i);
		await tick();
		skip();
	}
	return out;
}

console.log("frame-write" + drain(frameWrite(2)));
console.log("closure-write" + drain(closureWrite()));
console.log("loop-variable" + drain(loopVariable()));
console.log("text" + drainText(text()));
console.log("while" + drain(whileLoop()));
console.log("for-of" + drain(forOf()));
console.log("nested" + drain(nested()));
const lastOut = drain(lastRun(41));
console.log("last-run" + lastOut + " " + String(sink));
console.log("async-closure-write " + await asyncClosureWrite());
console.log("async-write-after" + await asyncWriteAfter());
console.log("async-loop-variable" + await asyncLoopVariable());
