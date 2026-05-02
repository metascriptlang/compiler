// E2E: actor model → C output
// Migrated/scaled-down from examples/benchActor* — actor runtime requires
// the C event loop + scheduler, so Bun-transpiled lang tests can't exercise
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
