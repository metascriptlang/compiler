// @stdout: woof|woof|woof|moo|woof meow
class Cat { meow(): string { return "meow"; } }
class Dog { bark(): string { return "woof"; } }
class Cow { moo(): string { return "moo"; } }
function pet(k: int32): Cat | Dog { return k > 0 ? new Cat() : new Dog(); }
function early(p: Cat | Dog): string {
	if (p instanceof Cat) { return p.meow(); }
	return p.bark();
}
function neg(p: Cat | Dog): string {
	if (!(p instanceof Cat)) { return p.bark(); }
	return "cat";
}
function three(p: Cat | Dog | Cow): string {
	if (p instanceof Cat) { return "c"; } else if (p instanceof Dog) { return "d"; } else { return p.moo(); }
}
function both(p: Cat | Dog): string {
	if (p instanceof Cat) return p.meow(); else return p.bark();
}
const p = pet(0);
let direct = "";
if (p instanceof Cat) direct = p.meow(); else direct = p.bark();
console.log([direct, early(new Dog()), neg(new Dog()), three(new Cow()), both(new Dog()) + " " + both(new Cat())].join("|"));
