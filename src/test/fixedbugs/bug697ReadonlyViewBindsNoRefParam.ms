// bug697 — a read-only view bound a `ref` / `out` parameter and was written through it
//
// Symptom:    `view[].heal()` (a `this ref` method), `bump(view[])` and `setOut(view[])` through
//             `Readonly<Ptr<Pet>>`, and `ro[0].heal()` through `Readonly<Pet[]>`, compiled and wrote
//             the backing value; a direct write through the same views was already refused.
// Root cause: binding an argument to a `ref` / `out` formal asked only the const and value-parameter
//             rules, not the read-only view rule the assignment path asks.
// Fix:        the `ref` / `out` argument path refuses a location reached through a read-only view.

import { compileToCWithStd, compileProjectToJSWithStd } from "../helpers";

const PRELUDE697 = `struct Pet { hearts: int32; }
	function heal(this ref p: Pet): void { p.hearts += 1; }
	function bump(ref p: Pet): void { p.hearts = 9; }
	function setOut(out p: Pet): void { p = { hearts: 3 }; }
	function look(this p: Pet): int32 { return p.hearts; }
	function lookValue(p: Pet): int32 { return p.hearts; }`;

function cError(body: string): string {
	const c = compileToCWithStd(`${PRELUDE697}
		function main(): void {
			let backing: Pet = { hearts: 1 };
			const view: Readonly<Ptr<Pet>> = backing as Ptr<Pet>;
			const ro: Readonly<Pet[]> = [{ hearts: 5 }];
			${body}
		}
		main();`);
	return c.ok ? "compiled" : c.error;
}

const REFUSED697 = "a read-only view never converts back to the mutable type";

test "bug697: a this ref method through an explicit deref of the view is refused" {
	assert cError(`view[].heal();`).includes(REFUSED697);
}

test "bug697: a ref and an out argument through the view are refused" {
	assert cError(`bump(view[]);`).includes(REFUSED697);
	assert cError(`setOut(view[]);`).includes(REFUSED697);
}

test "bug697: a this ref method on an element of a read-only array is refused" {
	assert cError(`ro[0].heal();`).includes(REFUSED697);
}

test "bug697: reads and value calls through the views compile" {
	assert cError(`const n: int32 = view[].look() + lookValue(view[]) + view[].hearts + ro[0].look();`) == "compiled";
}

test "bug697: the JS backend refuses the same binding" {
	const out = compileProjectToJSWithStd([{ entryPath: "test/main.ms", entrySource: `${PRELUDE697}
		let backing: Pet = { hearts: 1 };
		const view: Readonly<Ptr<Pet>> = backing as Ptr<Pet>;
		view[].heal();
	` }], "test/main.ms");
	assert out.includes(REFUSED697), out.slice(0, 300);
}
