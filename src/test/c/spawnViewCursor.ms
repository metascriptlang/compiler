// A task that writes data it owns takes no rc op on a view of a lent graph: the write is in another
// partition than the view's source (V5). Inference unit tests: `cursors.ms`.

import { compileToC } from "../helpers";

function thunkBodies(c: string): string {
	let out = "";
	let from = 0;
	for (const line of c.split("\n")) {
		if (line.contains("lifted_") && line.endsWith(") {") && !line.startsWith(" ") && !line.startsWith("\t")) {
			const open = c.indexOf(line, from);
			const close = c.indexOf("\n}", open);
			out = out + c.slice(open, close) + "\n";
			from = close;
		}
	}
	return out;
}

const PROGRAM = (holder: string, make: string) => `
class N { v: int32 = 1; next: N | null = null; }
${holder}
async function main(): Promise<int32> {
	const g = ${make};
	g.next = new N();
	const t = spawn(() => {
		let sum = 0;
		const own = ${make};
		for (let i = 0; i < 10; i += 1) {
			const view = g.next;
			own.next = new N();
			if (view != null) sum += view.v;
		}
		return sum;
	});
	return await t;
}
console.log(\`\${await main()}\`);
`;

test "E2E C: a task view of a lent graph takes no rc op beside a store to its own holder of the same type" {
	const r = compileToC(PROGRAM("", "new N()"));
	assert r.ok;
	const body = thunkBodies(r.ok ? r.value : "");
	assert body.length > 0;
	assert !body.contains("msIncrefCyclic(view");
	assert !body.contains("msDecrefCyclic(view");
}

test "E2E C: a task view of a lent graph takes no rc op beside a store to its own generic holder of the same type" {
	const r = compileToC(PROGRAM("class Cell<T> { v: int32 = 1; next: T | null = null; }", "new Cell<N>()"));
	assert r.ok;
	const body = thunkBodies(r.ok ? r.value : "");
	assert body.length > 0;
	assert !body.contains("msIncrefCyclic(view");
	assert !body.contains("msDecrefCyclic(view");
}

const CALLS = (callee: string, decl: string) => `
class N { v: int32 = 1; next: N | null = null; }
function nextOf(x: Readonly<N>): Readonly<N> | null { return x.next; }
async function main(): Promise<int32> {
	const g = new N();
	g.next = new N();
	const t = spawn(() => {
		${decl}
		let sum = 0;
		for (let i = 0; i < 10; i += 1) {
			const view = ${callee}(g);
			if (view != null) sum += view.v;
		}
		return sum;
	});
	return await t;
}
console.log(\`\${await main()}\`);
`;

function compiledThunks(source: string): string {
	const r = compileToC(source);
	return r.ok ? thunkBodies(r.value) : "";
}

test "E2E C: a task view of a lent graph through a function value of an inferred Readonly result takes no rc op" {
	const body = compiledThunks(CALLS("pick", "const pick = (x: Readonly<N>) => x.next;"));
	assert body.length > 0;
	assert !body.contains("msIncrefCyclic(dollarborrow");
	assert !body.contains("msIncrefCyclic(view");
	assert !body.contains("msDecrefCyclic(view");
}

test "E2E C: a task view of a lent graph through a function value of a declared Readonly result takes no rc op" {
	const body = compiledThunks(CALLS("pick", "const pick = (x: Readonly<N>): Readonly<N> | null => x.next;"));
	assert body.length > 0;
	assert !body.contains("msIncrefCyclic(dollarborrow");
	assert !body.contains("msIncrefCyclic(view");
	assert !body.contains("msDecrefCyclic(view");
}

test "E2E C: a task view of a lent graph through a direct call takes no rc op" {
	const body = compiledThunks(CALLS("nextOf", ""));
	assert body.length > 0;
	assert !body.contains("msIncrefCyclic(dollarborrow");
	assert !body.contains("msIncrefCyclic(view");
	assert !body.contains("msDecrefCyclic(view");
}

test "E2E C: a function value of an owning result is counted for its own fresh cell and takes no count on the lent graph" {
	const body = compiledThunks(CALLS("copy", "const copy = (x: Readonly<N>): N => { const n = new N(); n.v = x.v; return n; };"));
	assert body.length > 0;
	assert body.contains("msDecrefCyclic(view");
	assert !body.contains("msIncrefCyclic(dollarborrow");
}

test "E2E C: a view stays counted through a function value whose body writes a captured graph" {
	const r = compileToC(`
class N { v: int32 = 1; next: N | null = null; }
function run(): int32 {
	const g = new N();
	g.next = new N();
	const clear = (x: Readonly<N>): int32 => { g.next = null; return x.v; };
	const view = g.next;
	const a = clear(g);
	return view != null ? view.v + a : a;
}
console.log(\`\${run()}\`);
`);
	assert r.ok;
	assert (r.ok ? r.value : "").contains("msIncrefCyclic(view");
}

test "E2E C: a view stays counted through a capture-writing function value that returns nothing" {
	const r = compileToC(`
class N { v: int32 = 1; next: N | null = null; }
function use(n: Readonly<N> | null): int32 { return n != null ? n.v : 0; }
function run(): int32 {
	const g = new N();
	g.next = new N();
	const clear = (x: Readonly<N>) => { g.next = null; };
	const v = g.next;
	clear(g);
	return use(v);
}
console.log(\`\${run()}\`);
`);
	assert r.ok;
	assert (r.ok ? r.value : "").contains("msDecrefCyclic(v_");
}

test "E2E C: a view stays counted through a function value reassigned between calls" {
	const r = compileToC(`
class N { v: int32 = 1; next: N | null = null; }
function nextOf(x: Readonly<N>): Readonly<N> | null { return x.next; }
function run(): int32 {
	const g = new N();
	g.next = new N();
	let pick = nextOf;
	const a = pick(g);
	pick = (x: Readonly<N>): Readonly<N> | null => { g.next = null; return x.next; };
	const b = pick(g);
	return (a != null ? a.v : 0) + (b != null ? b.v : 0);
}
console.log(\`\${run()}\`);
`);
	assert r.ok;
	assert (r.ok ? r.value : "").contains("msDecrefCyclic(a_");
}

const SETS_TASK = (call: string) => `spawn(() => {
		let sum = 0;
		const own = new N();
		for (let i = 0; i < 10; i += 1) {
			const view = g.next;
			${call}
			if (view != null) sum += view.v;
		}
		return sum;
	})`;

const SETS = (call: string) => `
class N { v: int32 = 1; next: N | null = null; setNext(x: N): void { this.next = x; } }
async function main(): Promise<int32> {
	const g = new N();
	g.next = new N();
	const t = ${SETS_TASK(call)};
	const u = ${SETS_TASK(call)};
	return (await t) + (await u);
}
console.log(\`\${await main()}\`);
`;

test "E2E C: a task view of a lent graph takes no rc op beside a method call on its own object" {
	const body = compiledThunks(SETS("own.setNext(new N());"));
	assert body.length > 0;
	assert !body.contains("msIncrefCyclic(view");
	assert !body.contains("msDecrefCyclic(view");
}

const CAPTURE_WRITERS = (view: string, decl: string, arg: string, call: string, declare: string) => `
class L { v: int32 = 0; next: L | null = null; }
function apply(f: (o: L) => void, o: L): void { f(o); }
function f(${view}): int32 {
	${decl}
	const v = n.next;
	const own = new L();
	${declare}
	${call}
	return v != null ? v.v : 0;
}
const a = new L(); a.next = new L(); a.next!.v = 7;
console.log(\`\${f(${arg})}\`);
`;

test "E2E C: a view stays counted when a closure or nested function writes its source through a capture, called directly or passed on" {
	for (const declare of ["const clear = (o: L): void => { o.next = null; n.next = null; };", "function clear(o: L): void { o.next = null; n.next = null; }"]) {
		for (const call of ["clear(own);", "apply(clear, own);"]) {
			const asParam = compileToC(CAPTURE_WRITERS("n: L", "", "a", call, declare));
			assert asParam.ok;
			assert (asParam.ok ? asParam.value : "").contains("msDecrefCyclic(v_"), declare + call;
			const asLocal = compileToC(CAPTURE_WRITERS("", "const n = new L(); n.next = new L();", "", call, declare));
			assert asLocal.ok;
			assert (asLocal.ok ? asLocal.value : "").contains("msDecrefCyclic(v_"), declare + call;
		}
	}
}

const SENDABLE_CALLS = (args: string) => `
class N { kids: N[] = []; parent: N | null = null; }
class Facts { root: N | null = null; }
class Job { slot: int32 = 0; program: N | null = null; path: string = ""; }
class Res { n: int32 = 0; }
type Emitter = Sendable<(job: Readonly<Job>, facts: Readonly<Facts>, hot: boolean) => Res>;
function emitJob(job: Readonly<Job>, facts: Readonly<Facts>, hot: boolean): Res { const r = new Res(); r.n = job.slot + (hot ? 1 : 0); return r; }
function run(jobs: Job[], facts: Readonly<Facts>, entry: string, emitter: Emitter = emitJob): int32 {
	const pending: Promise<Res>[] = [];
	for (let next = 0; next < jobs.length; next += 1) {
		const job = jobs[next];
		pending.push(spawn(() => emitter(${args})));
	}
	let t = 0;
	for (let i = 0; i < pending.length; i += 1) t += (await pending[i]).n;
	return t;
}
const root = new N();
const f = new Facts(); f.root = root;
const a = new Job(); a.program = root; a.path = "a";
const b = new Job(); b.slot = 1; b.program = root; b.path = "b";
console.log(\`\${run([a, b], f, "a")}\`);
`;

test "E2E C: a task call through a Sendable value with Readonly formals takes no rc op on the lent arguments" {
	const body = compiledThunks(SENDABLE_CALLS("job, facts, false"));
	assert body.length > 0;
	assert !body.contains("msIncref");
	assert !body.contains("msDecref");
}

test "E2E C: a task call through a Sendable value takes no rc op on the operands spilled ahead of a short-circuit argument" {
	const body = compiledThunks(SENDABLE_CALLS(`job, facts, entry != "" && job.path == entry`));
	assert body.length > 0;
	assert !body.contains("msIncref");
	assert !body.contains("msDecref");
}

const FIELD_CALLS = (fnType: string) => `
class N { v: int32 = 1; next: N | null = null; }
class Holder { child: N | null = null; fn: ${fnType}; constructor(fn: ${fnType}) { this.fn = fn; } }
function read(n: Readonly<N>): int32 { return n.v; }
function run(h: Holder): int32 {
	const view = h.child;
	if (view == null) return 0;
	return h.fn(view) + view.v;
}
const h = new Holder(read);
h.child = new N();
console.log(\`\${run(h)}\`);
`;

test "E2E C: a view read beside a call of a Sendable field takes no rc op" {
	const r = compileToC(FIELD_CALLS("Sendable<(n: Readonly<N>) => int32>"));
	assert r.ok;
	assert !(r.ok ? r.value : "").contains("msIncrefCyclic(view");
}

test "E2E C: a view read beside a call of a plain function field stays counted" {
	const r = compileToC(FIELD_CALLS("(n: Readonly<N>) => int32"));
	assert r.ok;
	assert (r.ok ? r.value : "").contains("msIncrefCyclic(view");
}

const LOCAL_CLOSURE_CALLEE = (thunk: string) => `
class N { v: int32 = 1; next: N | null = null; }
function countUp(items: Readonly<N[]>): int32 {
	const ok = (x: Readonly<N>): boolean => x.v > 0;
	let n: int32 = 0;
	for (const x of items) if (ok(x)) n += 1;
	return n;
}
function tally(items: Readonly<N[]>): int32 {
	let n: int32 = 0;
	const bump = (x: Readonly<N>): void => { if (x.v > 0) n += 1; };
	for (const x of items) bump(x);
	return n;
}
function countFrom(head: Readonly<N>): int32 {
	const ok = (x: Readonly<N>): boolean => x.v > 0;
	let n: int32 = 0;
	let cur: Readonly<N> | null = head;
	while (cur != null) {
		if (ok(cur)) n += 1;
		cur = cur.next;
	}
	return n;
}
function outer(items: Readonly<N[]>): int32 {
	return countUp(items) + countFrom(items[0]);
}
function round(): int32 {
	const items: N[] = [new N(), new N()];
	items[0].next = items[1];
	const t = spawn(() => ${thunk});
	return await t;
}
console.log(\`\${round()}\`);
`;

function namedBody(c: string, name: string): string {
	for (const line of c.split("\n")) {
		if (line.contains(" " + name) && line.endsWith(") {") && !line.startsWith(" ") && !line.startsWith("\t")) {
			const open = c.indexOf(line, 0);
			return c.slice(open, c.indexOf("\n}", open));
		}
	}
	return "";
}

function countedOrMissing(c: string, name: string, callee: string): string {
	const body = namedBody(c, name);
	return body.contains(callee + "__") && !body.contains("msIncref") && !body.contains("msDecref") ? "" : name + ": " + body;
}

test "E2E C: a task passes its lent array uncounted to a callee that calls a local closure" {
	const r = compileToC(LOCAL_CLOSURE_CALLEE("countUp(items)"));
	assert r.ok;
	const fault = countedOrMissing(r.ok ? r.value : "", "dollarlifted_round_", "countUp");
	assert fault == "", fault;
}

test "E2E C: a task passes its lent array uncounted to a callee whose local closure writes its own captured counter" {
	const r = compileToC(LOCAL_CLOSURE_CALLEE("tally(items)"));
	assert r.ok;
	const fault = countedOrMissing(r.ok ? r.value : "", "dollarlifted_round_", "tally");
	assert fault == "", fault;
}

test "E2E C: a lent array and its element pass uncounted one call deeper to callees that call local closures" {
	const r = compileToC(LOCAL_CLOSURE_CALLEE("outer(items)"));
	assert r.ok;
	const c = r.ok ? r.value : "";
	const thunkFault = countedOrMissing(c, "dollarlifted_round_", "outer");
	assert thunkFault == "", thunkFault;
	const outerFault = countedOrMissing(c, "outer__", "countFrom");
	assert outerFault == "", outerFault;
}

const STORING_CLOSURE_CALLEE = (store: string) => `
class N { v: int32 = 1; }
function apply(f: () => void): void { f(); }
function storeFirst(xs: N[]): void {
	const store = (): void => { xs[0] = new N(); };
	${store};
}
function readAfterStore(xs: N[], x: Readonly<N>): int32 {
	const store = (): void => { xs[0] = new N(); };
	${store};
	return x.v;
}
function readAfterNestedStore(xs: N[], x: Readonly<N>): int32 {
	storeFirst(xs);
	return x.v;
}
function run(): int32 {
	const xs: N[] = [new N()];
	return readAfterStore(xs, xs[0]) + readAfterNestedStore(xs, xs[0]);
}
console.log(\`\${run()}\`);
`;

test "E2E C: an element passed to a callee whose local closure stores into the array stays counted, called directly, passed on or one call deeper" {
	for (const store of ["store()", "apply(store)"]) {
		const r = compileToC(STORING_CLOSURE_CALLEE(store));
		assert r.ok;
		const body = namedBody(r.ok ? r.value : "", "run__");
		assert body.contains("readAfterStore__"), body;
		assert body.split("msIncref(dollarborrow").length == 3, store + body;
	}
}
