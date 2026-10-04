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

test "readonlyPtrView: a field write through the view is refused" {
	assert cError(`view.hearts = 4;`).includes("cannot write through Readonly<Ptr<Pet>>");
}

test "readonlyPtrView: a field write through an explicit deref of the view is refused" {
	assert cError(`view[].hearts = 5;`).includes("cannot write through Readonly<Ptr<Pet>>");
}

test "readonlyPtrView: a write to a scalar pointee is refused" {
	assert cError(`const n: Readonly<Ptr<int32>> = backing as Ptr<int32>; n[] = 9;`)
		.includes("cannot write through Readonly<Ptr<int32>>");
}

test "readonlyPtrView: the view does not convert back to a writable Ptr" {
	const back = "never converts back to the mutable type";
	assert cError(`const back: Ptr<Pet> = view;`).includes(back);
	assert cError(`take(view);`).includes(back);
	assert cError(`const v = view as Ptr<Pet>;`)
		.includes("cannot cast away Readonly<Ptr<Pet>>");
}

test "readonlyPtrView: reads through the view compile" {
	const reads = `const h: int32 = view.hearts + view[].hearts;
		let copy: Pet = view[];
		copy.hearts = h;`;
	assert cError(reads) == "compiled";
}

test "readonlyPtrView: the JS backend refuses the same write" {
	const out = compileProjectToJSWithStd([{ entryPath: "test/main.ms", entrySource: `
		struct Pet { hearts: int32; }
		let backing: Pet = { hearts: 1 };
		const view: Readonly<Ptr<Pet>> = backing as Ptr<Pet>;
		view.hearts = 4;
	` }], "test/main.ms");
	assert out.includes("cannot write through Readonly<Ptr<Pet>>"), out.slice(0, 300);
}

function genericCError(helpers: string, body: string): string {
	const c = compileToCWithStd(`struct Pet { hearts: int32; }
		function grow(ref p: Pet): void { p.hearts = 9; }
		function heal(this ref self: Pet): void { self.hearts = 5; }
		${helpers}
		function main(): void {
			let backing: Pet = { hearts: 1 };
			let raw = backing as Ptr<Pet>;
			const at = raw as uint64;
			${body}
		}
		main();`);
	return c.ok ? "compiled" : c.error;
}

const GENERIC_HELPERS = `
	function viewG<T>(at: uint64): Readonly<Ptr<T>> { return at as Ptr<T>; }
	function viewOf<T>(p: Ptr<T>): Readonly<Ptr<T>> { return p; }
	function viewFixed<T>(at: uint64): Readonly<Ptr<Pet>> { return at as Ptr<Pet>; }
	function viewThis<T>(this at: uint64): Readonly<Ptr<T>> { return at as Ptr<T>; }
	function viewArr<T>(a: T[]): Readonly<T[]> { return a; }`;

test "readonlyPtrView: a generic returning the view with an explicit type argument keeps it read-only" {
	const refused = "cannot write through Readonly<Ptr<Pet>>";
	assert genericCError(GENERIC_HELPERS, `viewG<Pet>(at)[].hearts = 2;`).includes(refused);
	assert genericCError(GENERIC_HELPERS, `const b = viewG<Pet>(at); b[].hearts = 3;`).includes(refused);
}

test "readonlyPtrView: a generic returning the view with an inferred type argument keeps it read-only" {
	assert genericCError(GENERIC_HELPERS, `viewOf(raw)[].hearts = 2;`)
		.includes("cannot write through Readonly<Ptr<Pet>>");
}

test "readonlyPtrView: a generic whose return type names no type parameter keeps the view read-only" {
	assert genericCError(GENERIC_HELPERS, `viewFixed<int32>(at)[].hearts = 2;`)
		.includes("cannot write through Readonly<Ptr<Pet>>");
}

test "readonlyPtrView: a generic extension with a this receiver keeps the view read-only" {
	assert genericCError(GENERIC_HELPERS, `at.viewThis<Pet>()[].hearts = 2;`)
		.includes("cannot write through Readonly<Ptr<Pet>>");
}

test "readonlyPtrView: a ref argument and a this ref receiver are refused through the generic view" {
	const binds = "cannot pass an argument to a 'ref' or 'out' parameter through Readonly<Ptr<Pet>>";
	assert genericCError(GENERIC_HELPERS, `grow(viewG<Pet>(at)[]);`).includes(binds);
	assert genericCError(GENERIC_HELPERS, `viewG<Pet>(at)[].heal();`).includes("Readonly<Ptr<Pet>>");
}

test "readonlyPtrView: reads through the generic view compile" {
	assert genericCError(GENERIC_HELPERS, `const h: int32 = viewG<Pet>(at)[].hearts; backing.hearts = h;`) == "compiled";
}

test "readonlyPtrView: a generic returning a read-only array keeps the refusal" {
	assert genericCError(GENERIC_HELPERS, `let a: int32[] = [1]; viewArr<int32>(a)[0] = 1;`)
		.includes("cannot write through Readonly<int32[]>");
}

test "readonlyPtrView: the JS backend refuses the write through the generic view" {
	const out = compileProjectToJSWithStd([{ entryPath: "test/main.ms", entrySource: `
		struct Pet { hearts: int32; }
		function viewG<T>(at: uint64): Readonly<Ptr<T>> { return at as Ptr<T>; }
		let backing: Pet = { hearts: 1 };
		const at = (backing as Ptr<Pet>) as uint64;
		viewG<Pet>(at)[].hearts = 4;
	` }], "test/main.ms");
	assert out.includes("cannot write through Readonly<Ptr<Pet>>"), out.slice(0, 300);
}

struct Pet675 {
	hearts: int32;
}

function peek675(view: Readonly<Ptr<Pet675>>): int32 {
	return view.hearts + view[].hearts;
}

test "readonlyPtrView: a writable Ptr passes where the view is expected and reads see its writes" {
	let backing: Pet675 = { hearts: 1 };
	const raw = backing as Ptr<Pet675>;
	raw.hearts = 6;
	assert peek675(raw) == 12;
}
