interface Rec {
	log: string;
}

function pick(sel: int32, tag: string): string {
	if (sel == 0) {
		let kw = "";
		kw = "var-" + tag;
		if (kw.length == 0) { return "unreachable"; }
	}
	if (sel == 1) {
		const kw = match (sel) {
			1 => "uno",
			_ => "y",
		};
		return "m-" + kw;
	}
	return "p-" + sel.toString();
}

function both(tag: string): string {
	let total = "";
	if (tag.length > 0) {
		let kw = "";
		kw = "head-" + tag;
		total = total + kw;
	}
	if (tag.length > 1) {
		const kw = match (tag) {
			"ab" => "mid-" + tag,
			_ => "other",
		};
		total = total + "|" + kw;
	}
	return total;
}

type NestedIterationFn = () => number;

const nestedIterationArr: NestedIterationFn[] = [];
for (let nestedIterationI = 0; nestedIterationI < 2; nestedIterationI++) {
	let c: number = 0;
	const step = () => {
		const inc = () => { c = c + 1; };
		inc();
		return c;
	};
	nestedIterationArr.push(step);
}

function nestedIterationInFunction(): number[] {
	const out: number[] = [];
	for (let i = 0; i < 1; i++) {
		let c: number = 0;
		const step = () => {
			const inc = () => { c = c + 1; };
			inc();
			return c;
		};
		out.push(step());
		out.push(step());
	}
	return out;
}

function nestedIterationReadOnlyInner(): number[] {
	const arr: NestedIterationFn[] = [];
	for (let i = 0; i < 2; i++) {
		let c: number = 0;
		const step = () => {
			const rd = () => { return c; };
			c = c + 1;
			return rd();
		};
		arr.push(step);
	}
	const out: number[] = [];
	out.push(arr[0]());
	out.push(arr[1]());
	out.push(arr[0]());
	return out;
}

type LaterShadowThunk = () => string;

function laterShadowShadowed(): string {
	const names: string[] = ["a", "b", "c"];
	const fs: LaterShadowThunk[] = [];
	for (const j of names) {
		fs.push(() => { return j; });
	}
	let out = "";
	let ci = 0;
	while (ci < names.length) {
		const j = names[ci];
		out = out + j;
		ci = ci + 1;
	}
	let cl = "";
	for (const f of fs) {
		cl = cl + f();
	}
	return out + "|" + cl;
}

function laterShadowRenamed(): string {
	const names: string[] = ["a", "b", "c"];
	const fs: LaterShadowThunk[] = [];
	for (const j of names) {
		fs.push(() => { return j; });
	}
	let out = "";
	let ci = 0;
	while (ci < names.length) {
		const k = names[ci];
		out = out + k;
		ci = ci + 1;
	}
	return out;
}

type NestedShadowThunk = () => int32;

function nestedShadowBlockShadowInLoop(): string {
	const fns: NestedShadowThunk[] = [];
	const seen: int32[] = [];
	for (let i = 0; i < 3; i += 1) {
		let x = 100 + i;
		fns.push(() => x);
		{
			let x = 900 + i;
			seen.push(x);
			x = x + 1;
			seen.push(x);
		}
	}
	let out = "";
	for (const v of seen) { out = out + v.toString() + ","; }
	out = out + "|";
	for (const f of fns) { out = out + f().toString() + ","; }
	return out;
}

function nestedShadowBlockShadowNoLoop(): string {
	let x = 100;
	const f = () => x;
	let got = "";
	{
		let x = 900;
		got = got + x.toString() + ",";
		x = x + 1;
		got = got + x.toString() + ",";
	}
	return got + "cap=" + f().toString();
}

function nestedShadowShadowInNestedArrow(): string {
	let b = 50;
	const fb = () => b;
	const inner = (): int32 => { let b = 700; return b; };
	return inner().toString() + "," + fb().toString();
}

function nestedShadowShadowInIfBlock(): string {
	let a = 100;
	const fa = () => a;
	let got = 0;
	if (a > 0) { let a = 900; got = a; }
	return got.toString() + "," + fa().toString();
}

function nestedShadowShadowWithoutCapture(): string {
	let out = "";
	for (let i = 0; i < 2; i += 1) {
		let x = 100 + i;
		{
			let x = 900 + i;
			out = out + x.toString() + ",";
		}
		out = out + x.toString() + ",";
	}
	return out;
}

type IterationBindingGet = () => int32;

type IterationBindingSet = (v: int32) => void;

function iterationBindingOuterShared(): string {
	let total: int32 = 0;
	const reads: IterationBindingGet[] = [];
	const adds: IterationBindingSet[] = [];
	for (let i: int32 = 0; i < 2; i++) {
		reads.push((): int32 => total);
		adds.push((v: int32): void => { total = total + v; });
	}
	adds[0](5);
	adds[1](7);
	const afterAdds = total;
	total = 99;
	return `${afterAdds} ${reads[0]()} ${reads[1]()}`;
}

function iterationBindingContinue(): string {
	const fs: IterationBindingGet[] = [];
	for (let i: int32 = 0; i < 6; i++) {
		fs.push((): int32 => i);
		if (i % 2 == 0) {
			i = i + 1;
			continue;
		}
		if (i > 4) break;
	}
	let s = "";
	for (const f of fs) s = s + `${f()} `;
	return s;
}

function iterationBindingForOf(): int32 {
	let clicks: int32 = 0;
	const handlers: (() => void)[] = [];
	const names: string[] = ["a", "b"];
	for (const n of names) {
		handlers.push((): void => { clicks = clicks + n.length; });
	}
	for (const h of handlers) h();
	return clicks;
}

test "lexicalIdentity: interface field named log compiles and reads" {
	const r: Rec = { log: "field" };
	assert r.log == "field";
}

test "lexicalIdentity: closure capturing a local named log compiles and runs" {
	let log = "a";
	const w = (): string => log;
	log = log + "b";
	assert w() == "ab";
}

test "lexicalIdentity: match-expr var beside same-named let keeps its own slot" {
	assert pick(1, "t") == "m-uno";
	assert pick(0, "z") == "p-0";
}

test "lexicalIdentity: both blocks in one call: both values preserved" {
	assert both("ab") == "head-ab|mid-ab";
	assert both("x") == "head-x";
}

test "lexicalIdentity: module-level loop closure with nested writer keeps one persistent cell per iteration" {
	assert nestedIterationArr[0]() == 1;
	assert nestedIterationArr[0]() == 2;
	assert nestedIterationArr[1]() == 1;
}

test "lexicalIdentity: in-function loop + nested closure increments its own cell across calls" {
	const r = nestedIterationInFunction();
	assert r[0] == 1;
	assert r[1] == 2;
}

test "lexicalIdentity: escaping loop closures see per-iteration cells through a read-only inner" {
	const a = nestedIterationReadOnlyInner();
	assert a[0] == 1;
	assert a[1] == 1;
	assert a[2] == 2;
}

test "lexicalIdentity: closures still snapshot their own iteration" {
	const names: string[] = ["x", "y"];
	const fs: LaterShadowThunk[] = [];
	for (const s of names) {
		fs.push(() => { return s; });
	}
	let seen = "";
	for (const f of fs) {
		seen = seen + f();
	}
	assert seen == "xy";
}

test "lexicalIdentity: a closure made in a loop reads and writes the enclosing binding" {
	assert iterationBindingOuterShared() == "12 99 99";
}

test "lexicalIdentity: continue and break keep the iteration's copy" {
	assert iterationBindingContinue() == "1 3 5 ";
}

test "lexicalIdentity: for-of closures share the enclosing binding" {
	assert iterationBindingForOf() == 2;
}

interface BindingProbe { name: string; run: () => string; expected: string; }
test "lexicalIdentity: shadow scopes never alias a captured binding" {
	const probes: BindingProbe[] = [
		{ name: "later loop", run: laterShadowShadowed, expected: "abc|abc" },
		{ name: "renamed later loop", run: laterShadowRenamed, expected: "abc" },
		{ name: "nested block in loop", run: nestedShadowBlockShadowInLoop, expected: "900,901,901,902,902,903,|100,101,102," },
		{ name: "nested block", run: nestedShadowBlockShadowNoLoop, expected: "900,901,cap=100" },
		{ name: "nested arrow", run: nestedShadowShadowInNestedArrow, expected: "700,50" },
		{ name: "if block", run: nestedShadowShadowInIfBlock, expected: "900,100" },
		{ name: "uncaptured control", run: nestedShadowShadowWithoutCapture, expected: "900,100,901,101," },
	];
	for (const probe of probes) assert probe.run() == probe.expected, probe.name;
}
