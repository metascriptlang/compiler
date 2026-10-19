// @stdout: alias nodenodenodenodenodenode leafleafleafleafleafleaf
// @stdout: when node,node,node,node,leaf,leaf,leaf,leaf
// @stdout: bound keyedkeyedkeyed
// @stdout: direct truetruetrue
// note: `V extends object` asks whether V is an object in the TypeScript sense: a class, an interface, an array, a tuple, a function or a struct is; a string, a number, a boolean, an enum, a literal union and null are not. The alias picks its branch per instance, `isObject<T>()` answers the same question inside a generic body, and `<T extends object>` admits the same set. Same output on every backend.
import { isObject } from "std/typetraits";

interface Named { name: string; }
class Pet { name: string = "p"; }
struct Point { x: int32; y: int32; }
enum Color { Red, Green }
type Word = "a" | "b";

type Kind<V> = V extends object ? "node" : "leaf";

function kind<T>(x: T): string {
	when (isObject<T>()) { return "node"; } else { return "leaf"; }
}

function keyed<T extends object>(x: T): string { return "keyed"; }

const aliased: Kind<Pet>[] = ["node"];
const k2: Kind<Named> = "node";
const k3: Kind<string[]> = "node";
const k4: Kind<[int32, string]> = "node";
const k5: Kind<() => void> = "node";
const k6: Kind<Point> = "node";
const k7: Kind<string> = "leaf";
const k8: Kind<int32> = "leaf";
const k9: Kind<boolean> = "leaf";
const k10: Kind<Color> = "leaf";
const k11: Kind<Word> = "leaf";
const k12: Kind<null> = "leaf";
const pet = new Pet();
const named: Named = pet;
const p: Point = { x: 1, y: 2 };
console.log("alias " + aliased[0] + k2 + k3 + k4 + k5 + k6 + " " + k7 + k8 + k9 + k10 + k11 + k12);
console.log("when " + [kind(pet), kind(named), kind([1, 2]), kind(p), kind("s"), kind(1 as int32), kind(true), kind(Color.Red)].join(","));
console.log("bound " + keyed(pet) + keyed(named) + keyed([1]));
console.log("direct " + isObject<Pet>().toString() + isObject<int32 | null>().toString() + isObject<Pet | Named>().toString());
