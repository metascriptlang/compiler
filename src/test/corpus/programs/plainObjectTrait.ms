// Parity program — `isPlainObject<T>()` is true for an interface, a struct, an object-literal type, an
// array and a tuple, and false for a class instance, a function or closure, a Proxy, a primitive, a
// string, an enum, a nullable and a std Map; a distinct answers as its base. Read directly and per
// instance of a generic body, which is how a store decides whether to wrap a field.
//
// @stdout: direct class=false interface=true struct=true literal=true array=true tuple=true fn=false closure=false int=false number=false boolean=false string=false enum=false nullable=false map=false proxy=false generic=true genericClass=false distinctStruct=true distinctString=false distinctClass=false
// @stdout: when wrap,keep,wrap,wrap,wrap,keep,keep,keep,keep
// @exit: 0
import { isPlainObject } from "std/typetraits";

class Pet { name: string = "p"; }
interface Named { name: string; }
struct Point { x: int32; y: int32; }
type Literal = { a: int32; b: string };
enum Color { Red, Green }
struct Box<T> { v: T; }
class Shelf<T> { items: T[] = []; }
type Tag = distinct Point;
type Email = distinct string;
type Owner = distinct Pet;

class Trap<T> {
	get<K extends keyof T>(target: T, key: K): T[K] { return Reflect.get(target, key); }
}

function store<T>(x: T): string {
	when (isPlainObject<T>()) { return "wrap"; } else { return "keep"; }
}

const pet = new Pet();
const named: Named = { name: "n" };
const point: Point = { x: 1, y: 2 };
const lit: Literal = { a: 1, b: "b" };
const add = (a: int32): int32 => a + 1;
let base: int32 = 2;
const shift = (a: int32): int32 => a + base;

console.log(`direct class=${isPlainObject<Pet>()} interface=${isPlainObject<Named>()} struct=${isPlainObject<Point>()} literal=${isPlainObject<Literal>()} array=${isPlainObject<int32[]>()} tuple=${isPlainObject<[int32, string]>()} fn=${isPlainObject<() => void>()} closure=${isPlainObject<(a: int32) => int32>()} int=${isPlainObject<int32>()} number=${isPlainObject<number>()} boolean=${isPlainObject<boolean>()} string=${isPlainObject<string>()} enum=${isPlainObject<Color>()} nullable=${isPlainObject<Named | null>()} map=${isPlainObject<Map<string, int32>>()} proxy=${isPlainObject<Proxy<Named, Trap<Named> >>()} generic=${isPlainObject<Box<int32>>()} genericClass=${isPlainObject<Shelf<int32>>()} distinctStruct=${isPlainObject<Tag>()} distinctString=${isPlainObject<Email>()} distinctClass=${isPlainObject<Owner>()}`);
console.log("when " + [store(named), store(pet), store(point), store(lit), store([1, 2]), store(add), store(shift), store("s"), store(1 as int32)].join(","));
