// @stdout: ptr=7/6/6 var=b/c/d generic=5/6/6 pick=ptr rex/value rex nullable=7/7
// note: a receiver declared `Ptr<T>` or `Var<T>` is found in method form and behaves as the free call: `p.f()` writes through the pointer, a `Var<T>` receiver writes through to the caller's place like `this ref`, a generic `Ptr<Box<T>>` receiver binds `T`, overloads on `Ptr<T>` and `T` are picked by the receiver, and a narrowed `Ptr<T> | null` is a receiver. Same output on every backend.

struct Pet { hunger: uint16; name: string; }
struct Box<T> { item: T; count: int32; }

function feed(this pet: Ptr<Pet>, portions: uint16): uint16 {
	pet.hunger = pet.hunger - portions;
	return pet.hunger;
}
function rename(this pet: Var<Pet>, name: string): void { pet.name = name; }
function grow<T>(this b: Ptr<Box<T>>, by: int32): int32 {
	b.count = b.count + by;
	return b.count;
}
function which(this p: Ptr<Pet>): string { return "ptr " + p.name; }
function which(this p: Pet): string { return "value " + p.name; }

let arena: Pet[1] = [{ hunger: 10, name: "rex" }];
const pet = arena[0] as Ptr<Pet>;
const fed = pet.feed(3);
const freeFed = feed(pet, 1);
const ptrLine = `ptr=${fed}/${freeFed}/${arena[0].hunger}`;

let own: Pet = { hunger: 1, name: "a" };
own.rename("b");
const renamed = own.name;
rename(own, "c");
let pets: Pet[1] = [{ hunger: 1, name: "a" }];
pets[0].rename("d");
const varLine = `var=${renamed}/${own.name}/${pets[0].name}`;

let boxes: Box<string>[1] = [{ item: "x", count: 1 }];
const box = boxes[0] as Ptr<Box<string>>;
const grown = box.grow(4);
const freeGrown = grow(box, 1);
const genericLine = `generic=${grown}/${freeGrown}/${boxes[0].count}`;

const pickLine = `pick=${pet.which()}/${arena[0].which()}`;

let spare: Pet[1] = [{ hunger: 9, name: "b" }];
const maybe: Ptr<Pet> | null = spare[0] as Ptr<Pet>;
let nullableFed: uint16 = 0;
if (maybe != null) nullableFed = maybe.feed(2);
const nullableLine = `nullable=${nullableFed}/${spare[0].hunger}`;

console.log(`${ptrLine} ${varLine} ${genericLine} ${pickLine} ${nullableLine}`);
