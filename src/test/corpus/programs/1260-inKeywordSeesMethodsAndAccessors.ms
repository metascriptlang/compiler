// @stdout: talks silent
// @stdout: named plain
// @stdout: inherited silent
// @stdout: B C
// `"name" in u` holds for a member whose class declares `name` as a method or an accessor, its own or
// inherited, as it does for a field; narrowing an enum-discriminated union by `in` keeps the discriminant readable.
class Cat { speak(): string { return "meow"; } }
class Rock { weight: number = 1; }

function voice(p: Cat | Rock): string {
	if ("speak" in p) return p.speak() == "meow" ? "talks" : "odd";
	return "silent";
}
console.log(voice(new Cat()), voice(new Rock()));

class Tag { get name(): string { return "rex"; } }

function label(p: Tag | Rock): string {
	if ("name" in p) return "named";
	return "plain";
}
console.log(label(new Tag()), label(new Rock()));

class Pet { speak(): string { return "hi"; } }
class Puppy extends Pet { age: int32 = 1; }

function heard(p: Puppy | Rock): string {
	if ("speak" in p) return "inherited";
	return "silent";
}
console.log(heard(new Puppy()), heard(new Rock()));

enum K { A, B, C }
type U = { kind: K.A, x: number } | { kind: K.B, x: number } | { kind: K.C, y: number };

function kindOf(u: U): string {
	if ("x" in u) return u.kind == K.B ? "B" : "A";
	return "C";
}
console.log(kindOf({ kind: K.B, x: 5 }), kindOf({ kind: K.C, y: 1 }));
