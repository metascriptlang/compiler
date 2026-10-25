import { checkOnly } from "../helpers";

const PRELUDE = `
struct Pt { x: number; y: number; }
interface HasX { x: number; }
class Animal { name: string = "a"; }
class Dog extends Animal { bark(): string { return "woof"; } }
type Id = distinct int32;
function valueOf(this d: Id): int32 { return 99; }
type Name = distinct string;
function valueOf(this n: Name): string { return "vo"; }
type Spot = distinct Pt;
function valueOf(this s: Spot): int32 { return 42; }
type Ints = distinct int32[];
function valueOf(this a: Ints): int32[] { return [9]; }
type Tagged<T> = distinct int32;
function valueOf<T>(this d: Tagged<T>): int32 { return 99; }
function valueOf(this a: Animal): int32 { return 42; }
const id = (7 as int32) as Id;
const name = "abc" as Name;
const spot = ({ x: 1, y: 2 } as Pt) as Spot;
const ints = [1, 2] as Ints;
const tagged = (7 as int32) as Tagged<string>;
const pet: Animal = new Dog();
`;

function refusal(cast: string): string {
	return checkOnly(PRELUDE + "const r = " + cast + ";\n").errors.join("\n");
}

test "a cast valueOf cannot serve is refused naming the source type" {
	const cases: string[][] = [
		["id as boolean", "cannot convert Id to boolean — neither type overlaps the other, and its valueOf gives int32, which does not convert to boolean either"],
		["name as int32", "cannot convert Name to int32 — neither type overlaps the other, and its valueOf gives string, which does not convert to int32 either"],
		["spot as string", "cannot convert Spot to string — neither type overlaps the other, and its valueOf gives int32, which does not convert to string either"],
		["ints as number", "cannot convert Ints to number — neither type overlaps the other, and its valueOf gives int32[], which does not convert to number either"],
		["tagged as string | null", "cannot convert Tagged<string> to string | null — neither type overlaps the other, and its valueOf gives int32, which does not convert to string | null either"],
		["pet as string", "cannot convert Animal to string — neither type overlaps the other, and its valueOf gives int32, which does not convert to string either"],
	];
	for (const c of cases) {
		const text = refusal(c[0]);
		assert text.contains(c[1]), c[0] + " must be refused: " + text;
	}
}

test "a cast that holds without valueOf takes the base and reads nothing" {
	const casts: string[] = ["id as int32", "id as number", "id as int64 | null", "name as string", "spot as Pt", "spot as HasX",
		"ints as int32[]", "tagged as int32", "pet as Dog", "pet as Dog | null", "pet as int32"];
	for (const cast of casts) {
		const text = refusal(cast);
		assert text == "", cast + " must check: " + text;
	}
}
