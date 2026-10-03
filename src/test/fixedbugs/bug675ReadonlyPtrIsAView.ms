// bug675 — a write through Readonly<Ptr<T>> was accepted
//
// Symptom:    `view.hearts = 4`, `view[].hearts = 5` and `n[] = 9` compiled and wrote the
//             backing value, and the view converted back to a writable `Ptr<T>`.
// Root cause: Ptr was not a read-only view kind, so `Readonly<Ptr<T>>` was the plain
//             `Ptr<T>` and no read-only rule applied.
// Fix:        Ptr joins the view kinds (as Span did, NIM-REF CK-137): writes through the
//             view, casting it away and converting it back are refused; reads compile.

import { compileToCWithStd, compileProjectToJSWithStd } from "../helpers";

function cError(body: string): string {
	const c = compileToCWithStd(`struct Pet { hearts: int32; }
		function take(p: Ptr<Pet>): int32 { return p.hearts; }
		function main(): void {
			let backing: Pet = { hearts: 1 };
			const view: Readonly<Ptr<Pet>> = backing as Ptr<Pet>;
			${body}
		}
		main();`);
	return c.ok ? "compiled" : c.error;
}

test "bug675: a field write through the view is refused" {
	assert cError(`view.hearts = 4;`).includes("cannot write through Readonly<Ptr<Pet>>");
}

test "bug675: a field write through an explicit deref of the view is refused" {
	assert cError(`view[].hearts = 5;`).includes("cannot write through Readonly<Ptr<Pet>>");
}

test "bug675: a write to a scalar pointee is refused" {
	assert cError(`const n: Readonly<Ptr<int32>> = backing as Ptr<int32>; n[] = 9;`)
		.includes("cannot write through Readonly<Ptr<int32>>");
}

test "bug675: the view does not convert back to a writable Ptr" {
	const back = "never converts back to the mutable type";
	assert cError(`const back: Ptr<Pet> = view;`).includes(back);
	assert cError(`take(view);`).includes(back);
	assert cError(`const v = view as Ptr<Pet>;`)
		.includes("cannot cast away Readonly<Ptr<Pet>>");
}

test "bug675: reads through the view compile" {
	const reads = `const h: int32 = view.hearts + view[].hearts;
		let copy: Pet = view[];
		copy.hearts = h;`;
	assert cError(reads) == "compiled";
}

test "bug675: the JS backend refuses the same write" {
	const out = compileProjectToJSWithStd([{ entryPath: "test/main.ms", entrySource: `
		struct Pet { hearts: int32; }
		let backing: Pet = { hearts: 1 };
		const view: Readonly<Ptr<Pet>> = backing as Ptr<Pet>;
		view.hearts = 4;
	` }], "test/main.ms");
	assert out.includes("cannot write through Readonly<Ptr<Pet>>"), out.slice(0, 300);
}

struct Pet675 {
	hearts: int32;
}

function peek675(view: Readonly<Ptr<Pet675>>): int32 {
	return view.hearts + view[].hearts;
}

test "bug675: a writable Ptr passes where the view is expected and reads see its writes" {
	let backing: Pet675 = { hearts: 1 };
	const raw = backing as Ptr<Pet675>;
	raw.hearts = 6;
	assert peek675(raw) == 12;
}
