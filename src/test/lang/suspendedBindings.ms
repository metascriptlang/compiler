function* generatorElementInts(xs: int32[]): Iterator<int32> {
	for (const x of xs) {
		yield x;
	}
}

function* generatorElementStrings(xs: string[]): Iterator<string> {
	for (const x of xs) {
		yield x;
	}
}

function* generatorElementPairs(xs: string[]): Iterator<string> {
	for (const x of xs) {
		for (const y of xs) {
			yield x + y;
		}
	}
}

function* generatorShadowBranches(flag: boolean): Iterator<string> {
	if (flag) {
		const x: string = "str";
		yield x;
	} else {
		const x: int32 = 42;
		yield x.toString();
	}
	yield "end";
}

function* generatorShadowLoops(): Iterator<string> {
	let i: int32 = 0;
	while (i < 2) {
		const x: string = "s" + i.toString();
		yield x;
		i++;
	}
	let j: int32 = 0;
	while (j < 2) {
		const x: int32 = j * 10;
		yield x.toString();
		j++;
	}
}

type SuspendedBindingGet = () => int32;

async function suspendedBindingWork(x: int32): Promise<int32> {
	return x * 2;
}

async function suspendedBindingLoopOfAsync(): Promise<string> {
	let total: int32 = 0;
	const w = await suspendedBindingWork(5);
	const fns: (() => void)[] = [];
	for (let i: int32 = 0; i < 3; i++) {
		let j: int32 = i * 10;
		fns.push((): void => { total += i + j + w; });
		j = j + 1;
	}
	for (const f of fns) f();
	return `${total}`;
}

async function suspendedBindingAwaitInLoop(): Promise<string> {
	let total: int32 = 0;
	const fns: (() => void)[] = [];
	const reads: SuspendedBindingGet[] = [];
	for (let i: int32 = 0; i < 3; i++) {
		fns.push((): void => { total += i; });
		const w = await suspendedBindingWork(i);
		reads.push((): int32 => w);
	}
	for (const f of fns) f();
	let s = `${total}`;
	for (const r of reads) s = s + ` ${r()}`;
	return s;
}

function* suspendedBindingGenLoop(): Iterator<int32> {
	const fs: SuspendedBindingGet[] = [];
	let base: int32 = 0;
	for (let i: int32 = 0; i < 3; i++) {
		let j: int32 = i * 10;
		fs.push((): int32 => base + i + j);
		j = j + 1;
	}
	yield fs.length;
	base = 100;
	for (let k: int32 = 0; k < fs.length; k++) yield fs[k]();
}

test "suspendedBindings: for-of over int32[] inside a generator" {
	let sum: int32 = 0;
	for (const v of generatorElementInts([1, 2, 3])) sum = sum + v;
	assert sum == 6;
}

test "suspendedBindings: for-of over string[] inside a generator" {
	let out: string = "";
	for (const v of generatorElementStrings(["a", "b"])) out = out + v;
	assert out == "ab";
}

test "suspendedBindings: nested for-of inside a generator" {
	let out: string = "";
	for (const v of generatorElementPairs(["a", "b"])) out = out + v + ",";
	assert out == "aa,ab,ba,bb,";
}

test "suspendedBindings: same-named branch bindings of different types" {
	let out: string = "";
	for (const v of generatorShadowBranches(true)) out = out + v + ",";
	for (const v of generatorShadowBranches(false)) out = out + v + ",";
	assert out == "str,end,42,end,";
}

test "suspendedBindings: same-named loop bindings of different types" {
	let out: string = "";
	for (const v of generatorShadowLoops()) out = out + v + ",";
	assert out == "s0,s1,0,10,";
}

test "suspendedBindings: closures of a loop in an async function share its variables" {
	assert await suspendedBindingLoopOfAsync() == "66";
}

test "suspendedBindings: closures of a loop that awaits share the function's variables" {
	assert await suspendedBindingAwaitInLoop() == "3 0 2 4";
}

test "suspendedBindings: closures of a loop in a generator own their iteration and share the rest" {
	let s = "";
	for (const v of suspendedBindingGenLoop()) s = s + `${v} `;
	assert s == "3 101 112 123 ";
}

struct ResumedPoint { x: int32; y: int32; }
class ResumedTag {
	name: string;
	constructor(name: string) { this.name = name; }
}
async function initialValue(value: int32): Promise<int32> { return value; }
async function branchInt(suspend: boolean): Promise<int32> {
	let value: int32;
	if (suspend) { const loaded = await initialValue(1); value = loaded; }
	else { value = 7; }
	return value;
}
async function branchString(suspend: boolean): Promise<string> {
	let value: string;
	if (suspend) { const loaded = await initialValue(1); value = `n${loaded}`; }
	else { value = "seven"; }
	return value;
}
async function branchPoint(suspend: boolean): Promise<ResumedPoint> {
	let value: ResumedPoint;
	if (suspend) { const loaded = await initialValue(1); value = { x: loaded, y: loaded }; }
	else { value = { x: 7, y: 8 }; }
	return value;
}
async function branchTag(suspend: boolean): Promise<ResumedTag> {
	let value: ResumedTag;
	if (suspend) { const loaded = await initialValue(1); value = new ResumedTag(`n${loaded}`); }
	else { value = new ResumedTag("seven"); }
	return value;
}

test "suspendedBindings: uninitialized locals share their storage across suspended and unsuspended branches" {
	for (const suspend of [false, true]) {
		assert await branchInt(suspend) == (suspend ? 1 : 7);
		assert await branchString(suspend) == (suspend ? "n1" : "seven");
		const point = await branchPoint(suspend);
		assert point.x == (suspend ? 1 : 7) && point.y == (suspend ? 1 : 8);
		const tag = await branchTag(suspend);
		assert tag.name == (suspend ? "n1" : "seven");
	}
}
