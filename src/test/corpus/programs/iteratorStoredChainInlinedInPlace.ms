// @xfail(raiser): a call through the narrowed `return` field inside a generic is an unknown host function (inbox 2026-10-25-raiser-calls-a-narrowed-nullable-function-field-in-a-generic-as-a-host-function)
// An iterator chain stored in a const and read once is expanded at its read, and keeps the
// order Node shows: arguments and checks at the declaration, the body at the read.
// @stdout: ok
let log: string[] = [];
const lines: string[] = [];

function* gen(tag: string, n: int32): Iterator<int32> {
	log.push(`start ${tag}`);
	try {
		for (let i = 0; i < n; i++) {
			log.push(`${tag}${i}`);
			yield i;
		}
	} finally {
		log.push(`close ${tag}`);
	}
}

function arg(n: int32): int32 {
	log.push(`arg ${n}`);
	return n;
}

function total(it: Iterator<int32>): int32 {
	let t = 0;
	for (const x of it) t += x;
	return t;
}

function flush(name: string): void {
	lines.push(`${name}: ${log.join(" ")}`);
	log = [];
}

function argsAtDeclaration(): void {
	let n: int32 = 2;
	const it = gen("a", arg(n));
	n = 5;
	log.push(`between ${n}`);
	for (const x of it) log.push(`x${x}`);
	flush("args");
}

function checkAtDeclaration(): void {
	const xs: int32[] = [1, 2, 3];
	try {
		const t = xs.values().take(-1);
		log.push("after");
		for (const x of t) log.push(`x${x}`);
	} catch (e) {
		log.push(e instanceof RangeError ? "RangeError" : "other");
	}
	flush("check");
}

function lazyLiveView(): void {
	const xs: int32[] = [1, 2];
	const v = xs.values().map((x: int32): int32 => {
		log.push(`m${x}`);
		return x * 10;
	});
	xs.push(3);
	log.push("pushed");
	for (const x of v) log.push(`x${x}`);
	flush("lazy");
}

function unreadPath(c: boolean): void {
	const it = gen("d", 2);
	log.push("made");
	if (c) {
		for (const x of it) log.push(`x${x}`);
	}
	flush(`path ${c}`);
}

function nestedLoop(): void {
	const it = gen("e", 2);
	for (let k = 0; k < 2; k++) {
		for (const x of it) log.push(`k${k}x${x}`);
	}
	flush("loop");
}

function earlyExit(): void {
	const it = gen("f", 3);
	for (const x of it) {
		if (x == 1) break;
		log.push(`x${x}`);
	}
	flush("break");
}

function consumer(): void {
	const it = gen("g", 3);
	log.push("before");
	const s = total(it);
	log.push(`sum ${s}`);
	flush("consumer");
}

function chained(): void {
	const a = gen("h", 3);
	log.push("a made");
	const b = a.map((x: int32): int32 => x + 100);
	log.push("b made");
	for (const x of b) log.push(`x${x}`);
	flush("chained");
}

argsAtDeclaration();
checkAtDeclaration();
lazyLiveView();
unreadPath(true);
unreadPath(false);
nestedLoop();
earlyExit();
consumer();
chained();

const expected: string[] = [
	"args: arg 2 between 5 start a a0 x0 a1 x1 close a",
	"check: RangeError",
	"lazy: pushed m1 x10 m2 x20 m3 x30",
	"path true: made start d d0 x0 d1 x1 close d",
	"path false: made",
	"loop: start e e0 k0x0 e1 k0x1 close e",
	"break: start f f0 x0 f1 close f",
	"consumer: before start g g0 g1 g2 close g sum 3",
	"chained: a made b made start h h0 x100 h1 x101 h2 x102 close h",
];
for (const line of lines) console.log(line);
if (lines.length != expected.length) throw new Error(`${lines.length} lines, expected ${expected.length}`);
for (let i = 0; i < expected.length; i += 1) {
	if (lines[i] != expected[i]) throw new Error(`line ${i}: got "${lines[i]}", expected "${expected[i]}"`);
}
console.log("ok");
