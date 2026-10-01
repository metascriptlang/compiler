// Symptom: a function whose receiver is declared `this p: Ptr<T>` or `this p: Var<T>` was "Property 'f' does not exist on type 'T'" when called `p.f()`, on C and JS, while the free call `f(p)` worked; a C-header struct behind `Ptr<T>` failed the same way.
// Root cause: receiver matching compared the written wrapper name (`Ptr`, `Var`) with the object's type name and looked through `Ref` alone when comparing symbols; Nim relates a `ptr T` or `var T` formal through its base (sigmatch.nim typeRel, tyPtr and tyVar).
// Fix: a receiver is matched to the type it reaches through `Ptr`, `Var` or `Ref` and related as argument 0; `this x: Var<T>` registers as `this ref x: T`. Rule pinned: `p.f()` ≡ `f(p)` for every receiver spelling.

struct Pet616 { hunger: uint16; name: string; }
struct Box616<T> { item: T; count: int32; }

function feed(this pet: Ptr<Pet616>, portions: uint16): uint16 {
	pet.hunger = pet.hunger - portions;
	return pet.hunger;
}
function rename(this pet: Var<Pet616>, name: string): void { pet.name = name; }
function grow<T>(this b: Ptr<Box616<T>>, by: int32): int32 {
	b.count = b.count + by;
	return b.count;
}
function which(this p: Ptr<Pet616>): string { return "ptr " + p.name; }
function which(this p: Pet616): string { return "value " + p.name; }

test "bug616: a Ptr<T> receiver writes through like the free call" {
	let arena: Pet616[1] = [{ hunger: 10, name: "a" }];
	const pet = arena[0] as Ptr<Pet616>;
	assert pet.feed(3) == 7;
	assert feed(pet, 1) == 6;
	assert arena[0].hunger == 6;
}

test "bug616: a Var<T> receiver writes through like a this ref receiver" {
	let pet: Pet616 = { hunger: 1, name: "a" };
	pet.rename("b");
	assert pet.name == "b";
	rename(pet, "c");
	assert pet.name == "c";
	let arena: Pet616[1] = [{ hunger: 1, name: "a" }];
	arena[0].rename("d");
	assert arena[0].name == "d";
}

test "bug616: a generic Ptr receiver binds its type argument" {
	let boxes: Box616<string>[1] = [{ item: "x", count: 1 }];
	const b = boxes[0] as Ptr<Box616<string>>;
	assert b.grow(4) == 5;
	assert grow(b, 1) == 6;
	assert boxes[0].count == 6;
}

test "bug616: overloads on Ptr<T> and T are picked by the receiver" {
	let arena: Pet616[1] = [{ hunger: 1, name: "rex" }];
	const p = arena[0] as Ptr<Pet616>;
	assert p.which() == "ptr rex";
	assert arena[0].which() == "value rex";
	assert which(p) == p.which();
}

test "bug616: a narrowed Ptr<T> | null receiver" {
	let arena: Pet616[1] = [{ hunger: 9, name: "a" }];
	const q: Ptr<Pet616> | null = arena[0] as Ptr<Pet616>;
	if (q != null) assert q.feed(2) == 7;
	assert arena[0].hunger == 7;
}
