// @stdout: 7|7|7|7|7|7|abc|abc|abc|abc|1|1|1|2|null|woof|a
struct Pt { x: number; y: number; }
struct Box<T> { v: T; }
type Id = distinct int32;
type Tagged<T> = distinct int32;
type Name = distinct string;
type Label<T> = distinct string;
type Spot = distinct Pt;
type Boxed<T> = distinct Box<T>;
class Animal { name: string = "a"; }
class Dog extends Animal { bark(): string { return "woof"; } }
type Pet = distinct Animal;

const id = (7 as int32) as Id;
const tagged = (7 as int32) as Tagged<string>;
const name = "abc" as Name;
const label = "abc" as Label<int32>;
const spot = ({ x: 1, y: 2 } as Pt) as Spot;
const pet = (new Dog() as Animal) as Pet;
const boxed = ({ v: 2 } as Box<int32>) as Boxed<int32>;

function show(p: Pt | null): string { return p === null ? "null" : `${p.x}`; }

const stored = name as string | null;
const either = spot as Pt | string;
const parts: string[] = [
	`${id as int32 | null}`,
	`${tagged as int32 | null}`,
	`${id as number | null}`,
	`${tagged as int64 | null}`,
	`${id as int32 | string}`,
	`${tagged as string | int32}`,
	`${name as string | null}`,
	`${stored}`,
	`${label as string | null}`,
	`${name as string | int32}`,
	show(spot as Pt | null),
	show(either as Pt),
	`${(spot as Pt | null)!.x}`,
	`${(boxed as Box<int32> | null)!.v}`,
	show(null as Spot | null as Pt | null),
	(pet as Dog | null)!.bark(),
	(pet as Animal | null)!.name,
];
console.log(parts.join("|"));
