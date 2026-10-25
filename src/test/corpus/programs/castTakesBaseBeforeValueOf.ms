// @stdout: 7|7|7|1|1|abc|2|2|5|5|woof|woof|button|reads 0|vo|vo|42|42|99|tv|42|reads 7
struct Pt { x: number; y: number; }
struct Box<T> { v: T; }
interface HasX { x: number; }
class Animal { name: string = "a"; }
class Dog extends Animal { bark(): string { return "woof"; } }
type Role = "button" | "link";

let reads = 0;

type Id = distinct int32;
function valueOf(this d: Id): string { reads += 1; return "vo"; }
type Spot = distinct Pt;
function valueOf(this s: Spot): Pt { reads += 1; return { x: 9, y: 9 }; }
type Name = distinct string;
function valueOf(this n: Name): int32 { reads += 1; return 42; }
type Ints = distinct int32[];
function valueOf(this a: Ints): int32 { reads += 1; return 42; }
type Tagged<T> = distinct int32;
function valueOf<T>(this d: Tagged<T>): string { reads += 1; return "tv"; }
type Boxed<T> = distinct Box<T>;
function valueOf<T>(this b: Boxed<T>): int32 { reads += 1; return 99; }
function valueOf(this a: Animal): int32 { reads += 1; return 42; }
type Inner = distinct (() => Role);
type Outer = distinct Inner;
function valueOf(this o: Outer): Role { reads += 1; return "link"; }

const id = (7 as int32) as Id;
const spot = ({ x: 1, y: 2 } as Pt) as Spot;
const name = "abc" as Name;
const ints = [1, 2] as Ints;
const tagged = (5 as int32) as Tagged<string>;
const boxed = ({ v: 1 } as Box<int32>) as Boxed<int32>;
const pet: Animal = new Dog();
const outer = (((): Role => "button") as Inner) as Outer;

const parts: string[] = [
	`${id as int32}`,
	`${id as number}`,
	`${id as int64}`,
	`${(spot as Pt).x}`,
	`${(spot as HasX).x}`,
	name as string,
	`${(ints as int32[]).length}`,
	`${(ints as int32[])[1]}`,
	`${tagged as int32}`,
	`${tagged as number}`,
	(pet as Dog).bark(),
	(pet as Dog | null)!.bark(),
	((outer as Inner) as () => Role)(),
];
parts.push(`reads ${reads}`);
parts.push(id as string);
parts.push(`${(id as string | null)!}`);
parts.push(`${name as int32}`);
parts.push(`${ints as number}`);
parts.push(`${boxed as int32}`);
parts.push(tagged as string);
parts.push(`${pet as int32}`);
parts.push(`reads ${reads}`);
console.log(parts.join("|"));
