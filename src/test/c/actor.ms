// E2E: actor model → C output
// Migrated/scaled-down from examples/benchActor* — actor runtime requires
// the C event loop + scheduler, which lang tests can't exercise
// it. Runtime correctness is covered by examples/benchActor1M.ms and
// examples/benchActorScale.ms (manual benchmarks). Here we only verify the
// pipeline compiles for the canonical actor patterns at small scale (100
// actors).

import { compileToC } from "../helpers";

test "E2E C: single actor SEND + CALL compiles" {
	const src = `
actor Counter {
	private n: number = 0;
	bump(): void { this.n = this.n + 1; }
	get(): number { return this.n; }
}

async function main(): Promise<void> {
	const c = new Counter();
	let i = 0;
	while (i < 100) { c.bump(); i = i + 1; }
	const n = await c.get();
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: 100 actors fan-out compiles" {
	const src = `
actor Worker {
	private n: number = 0;
	bump(): void { this.n = this.n + 1; }
	get(): number { return this.n; }
}

async function main(): Promise<void> {
	const COUNT = 100;
	const actors: Worker[] = [];
	let i = 0;
	while (i < COUNT) { actors.push(new Worker()); i = i + 1; }

	for (const a of actors) { a.bump(); }

	let sum = 0;
	let j = 0;
	while (j < COUNT) {
		sum = sum + (await actors[j].get());
		j = j + 1;
	}
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: actor with parameterized message compiles" {
	const src = `
actor Adder {
	private sum: number = 0;
	add(x: number): void { this.sum = this.sum + x; }
	total(): number { return this.sum; }
}

async function main(): Promise<void> {
	const a = new Adder();
	let i = 1;
	while (i <= 10) { a.add(i); i = i + 1; }
	const t = await a.total();
}
`;
	const c = compileToC(src);
	assert c.ok;
}

// ===== PARALOCK Phase 6 S1/S3 + Phase 9 E40: actor spawn thunk rules =====

test "E2E C: S1/E61 — bare 'this' capture in spawn thunk fails" {
	const src = `
actor W {
	data: number = 0;
	run(): number {
		const r = await spawn(() => { console.log(this); return 0; });
		return r;
	}
}
`;
	const c = compileToC(src);
	assert !c.ok;
	if (!c.ok) { assert c.error.contains("PARALOCK S1/E61"); }
}

test "E2E C: S1/E61 — method call on 'this' in spawn thunk fails" {
	const src = `
actor W {
	rebuild(): void {}
	run(): number {
		const r = await spawn(() => { this.rebuild(); return 0; });
		return r;
	}
}
`;
	const c = compileToC(src);
	assert !c.ok;
	if (!c.ok) {
		assert c.error.contains("PARALOCK S1/E61");
		assert c.error.contains("rebuild");
	}
}

test "E2E C: S3/E62 — field assignment in spawn thunk fails" {
	const src = `
actor W {
	n: number = 0;
	run(): number {
		const r = await spawn(() => { this.n = 5; return 0; });
		return r;
	}
}
`;
	const c = compileToC(src);
	assert !c.ok;
	if (!c.ok) {
		assert c.error.contains("PARALOCK S3/E62");
		assert c.error.contains("'n'");
	}
}

test "E2E C: S3/E62 — compound assignment in spawn thunk fails" {
	const src = `
actor W {
	n: number = 0;
	run(): number {
		const r = await spawn(() => { this.n += 1; return 0; });
		return r;
	}
}
`;
	const c = compileToC(src);
	assert !c.ok;
	if (!c.ok) { assert c.error.contains("PARALOCK S3/E62"); }
}

test "E2E C: S3/E62 — increment of captured field fails" {
	const src = `
actor W {
	n: number = 0;
	run(): number {
		const r = await spawn(() => { this.n++; return 0; });
		return r;
	}
}
`;
	const c = compileToC(src);
	assert !c.ok;
	if (!c.ok) { assert c.error.contains("PARALOCK S3/E62"); }
}

test "E2E C: S3/E62 — deep write through captured field fails" {
	const src = `
actor W {
	xs: number[] = [1, 2];
	run(): number {
		const r = await spawn(() => { this.xs[0] = 9; return 0; });
		return r;
	}
}
`;
	const c = compileToC(src);
	assert !c.ok;
	if (!c.ok) {
		assert c.error.contains("PARALOCK S3/E62");
		assert c.error.contains("'xs'");
	}
}

test "E2E C: S1/S3 — read-only field borrow in spawn thunk compiles" {
	const src = `
actor R {
	items: number[] = [10, 20, 30];
	sum(): number {
		const r = await spawn(() => {
			let t = 0;
			for (const v of this.items) { t = t + v; }
			return t;
		});
		return r;
	}
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: S1 scope — 'this' capture in a CLASS method spawn is allowed" {
	const src = `
class K {
	x: number = 1;
	async m(): Promise<number> {
		const r = await spawn(() => this.x + 1);
		return r;
	}
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: E40 — sequential await spawn in loop stays a warning" {
	const src = `
async function main(): Promise<void> {
	const xs: number[] = [1, 2, 3];
	for (const x of xs) {
		const r = await spawn(() => x * 2);
	}
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: E40 — warning text emitted (visible alongside an error)" {
	const src = `
actor B {
	run(): number {
		const r = await spawn(() => { console.log(this); return 0; });
		return r;
	}
}
async function main(): Promise<void> {
	const xs: number[] = [1, 2];
	for (const x of xs) {
		const r = await spawn(() => x);
	}
}
`;
	const c = compileToC(src);
	assert !c.ok;
	if (!c.ok) {
		assert c.error.contains("PARALOCK E40/E41");
		assert c.error.contains("PARALOCK S1/E61");
	}
}

test "E2E C: S3/E62 — move out of captured field fails" {
	const src = `
actor W {
	entries: string[] = ["a"];
	run(): number {
		const r = await spawn(() => { const t = move this.entries; return 0; });
		return r;
	}
}
`;
	const c = compileToC(src);
	assert !c.ok;
	if (!c.ok) { assert c.error.contains("PARALOCK S3/E62"); }
}

test "E2E C: S3 — captured field as out argument is rejected (parser today; S3 walker if out-member ever parses)" {
	const src = `
extern function takeOut(out x: number): void;
actor W {
	n: number = 0;
	run(): number {
		const r = await spawn(() => { takeOut(out this.n); return 0; });
		return r;
	}
}
`;
	const c = compileToC(src);
	assert !c.ok;
}

test "E2E C: S3/E62 — write through a nested closure inside the thunk fails" {
	const src = `
actor W {
	n: number = 0;
	run(): number {
		const r = await spawn(() => {
			const g = () => { this.n = 7; };
			g();
			return 0;
		});
		return r;
	}
}
`;
	const c = compileToC(src);
	assert !c.ok;
	if (!c.ok) { assert c.error.contains("PARALOCK S3/E62"); }
}

test "E2E C: S1/S3 — read through a nested closure inside the thunk compiles" {
	const src = `
actor W {
	n: number = 5;
	run(): number {
		const r = await spawn(() => {
			const g = () => this.n + 1;
			return g();
		});
		return r;
	}
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: S3/E62 — chained deep member write fails, names the root field" {
	const src = `
interface Cfg { depth: number; }
actor W {
	cfg: Cfg = { depth: 1 };
	run(): number {
		const r = await spawn(() => { this.cfg.depth = 3; return 0; });
		return r;
	}
}
`;
	const c = compileToC(src);
	assert !c.ok;
	if (!c.ok) {
		assert c.error.contains("PARALOCK S3/E62");
		assert c.error.contains("'cfg'");
	}
}

test "E2E C: E40 — fires in while loops too" {
	const src = `
actor B {
	run(): number {
		const r = await spawn(() => { console.log(this); return 0; });
		return r;
	}
}
async function main(): Promise<void> {
	let i = 0;
	while (i < 3) {
		const r = await spawn(() => 1);
		i = i + 1;
	}
}
`;
	const c = compileToC(src);
	assert !c.ok;
	if (!c.ok) { assert c.error.contains("PARALOCK E40/E41"); }
}

test "E2E C: E40 — await spawn inside a closure in a loop does NOT warn" {
	const src = `
actor B {
	run(): number {
		const r = await spawn(() => { console.log(this); return 0; });
		return r;
	}
}
async function main(): Promise<void> {
	const xs: number[] = [1, 2];
	for (const x of xs) {
		const f = async () => {
			const r = await spawn(() => x);
			return r;
		};
	}
}
`;
	const c = compileToC(src);
	assert !c.ok;
	if (!c.ok) {
		assert c.error.contains("PARALOCK S1/E61");
		assert !c.error.contains("PARALOCK E40/E41");
	}
}
