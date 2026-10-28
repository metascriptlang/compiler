import { compileToCWithStd } from "../helpers";

const COUNTER = "interface Counter { n: int32; }";
const LOCK_NAMESAKE = "function lockedUpdate(g: int32, fn: (v: int32) => int32): void { fn(g); }";

function outcome(declarations: string, body: string): string {
	const source = declarations + "\nfunction run(): int32 { " + body + " }\n";
	const result = compileToCWithStd(source + "console.log(`${run()}`);");
	return result.ok ? "compiled" : result.error;
}

test "paralockLicences: a callback handed to a lock opens no binding the spawn thunk captured" {
	const cases = [
		{
			name: "a gate made inside the thunk",
			declarations: COUNTER,
			body: `
				const c: Counter = { n: 0 };
				const f = spawn(() => {
					const gate = new Locked<int32>(0);
					lockedUpdate(gate, (v: int32): int32 => { c.n = c.n + 1; return v; });
					return 0;
				});
				await f;
				return c.n;
			`,
			refusal: "cannot write through Readonly<Counter>",
		},
		{
			name: "a gate shared with the parent",
			declarations: COUNTER,
			body: `
				const gate = new Locked<int32>(0);
				const c: Counter = { n: 0 };
				const f = spawn(() => {
					lockedUpdate(gate, (v: int32): int32 => { c.n = c.n + 1; return v + 1; });
					return 0;
				});
				await f;
				return c.n;
			`,
			refusal: "cannot write through Readonly<Counter>",
		},
		{
			name: "a read section",
			declarations: COUNTER,
			body: `
				const gate = new Locked<int32>(0);
				const c: Counter = { n: 0 };
				const f = spawn(() => lockedRead(gate, (v: int32): int32 => {
					c.n = v + 1;
					return c.n;
				}));
				return await f;
			`,
			refusal: "cannot write through Readonly<Counter>",
		},
		{
			name: "a mutating builtin on a captured array",
			declarations: COUNTER,
			body: `
				const gate = new Locked<int32>(0);
				const items: int32[] = [];
				const f = spawn(() => {
					lockedUpdate(gate, (v: int32): int32 => { items.push(9); return v; });
					return 0;
				});
				await f;
				return items.length;
			`,
			refusal: "'push' mutates its receiver",
		},
		{
			name: "a user function that shares the lock function's name",
			declarations: COUNTER + "\n" + LOCK_NAMESAKE,
			body: `
				const c: Counter = { n: 0 };
				const f = spawn(() => {
					lockedUpdate(0, (v: int32): int32 => { c.n = c.n + 1; return v; });
					return 0;
				});
				await f;
				return c.n;
			`,
			refusal: "cannot write through Readonly<Counter>",
		},
	];
	for (const item of cases) {
		const got = outcome(item.declarations, item.body);
		assert got.contains(item.refusal), item.name + ": " + got;
	}
}

test "paralockLicences: a class instance bound outside the thunk is read-only inside it" {
	const got = outcome("class Box { n: int32 = 0; }", `
		const b = new Box();
		return await spawn((): int32 => { b.n = 4; return b.n; });
	`);
	assert got.contains("cannot write through Readonly<Box>"), got;
}

test "paralockLicences: a Locked payload holding a raw address names the address, and a fixed array of numbers is plain data" {
	const field = outcome("struct H { p: Ptr<void>; n: int32; }", `
		const c = new Locked<H>({ p: null as unknown as Ptr<void>, n: 1 });
		return 0;
	`);
	assert field.contains("holds the raw address 'Ptr<void>'"), field;
	const bare = outcome("", `
		const b = new Locked<Ptr<int32>>(null as unknown as Ptr<int32>);
		return 0;
	`);
	assert bare.contains("holds the raw address 'Ptr<int32>'"), bare;
	const cells = outcome("", `
		const a = new Locked<int32[4]>([1, 2, 3, 4]);
		return 0;
	`);
	assert !cells.contains("payload must be plain data"), cells;
}
