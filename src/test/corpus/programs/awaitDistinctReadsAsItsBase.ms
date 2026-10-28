// Parity program — a Promise of a distinct type is awaited as its base type is: the future stores
// and reads the distinct value the way it stores the base.
// Axes: distinct int32, distinct string, distinct struct, distinct class; awaited in an async function
// and at top level.
//
// @stdout: 7 ada 7 5
// @stdout: 8 6
// @exit: 0

type Id = distinct int32;
type Name = distinct string;
interface P { x: int32; y: int32; }
type Pt = distinct P;
class Box {
	v: int32;
	constructor(v: int32) { this.v = v; }
}
type BoxId = distinct Box;

async function getId(): Promise<Id> { return (7 as int32) as Id; }
async function getName(): Promise<Name> { return "ada" as Name; }
async function getPt(): Promise<Pt> {
	const p: P = { x: 3, y: 4 };
	return p as Pt;
}

async function getBox(): Promise<BoxId> { return new Box(5) as BoxId; }

async function all(): Promise<string> {
	const id = await getId();
	const name = await getName();
	const pt = await getPt();
	const box = await getBox();
	return `${id as int32} ${name as string} ${(pt as P).x + (pt as P).y} ${(box as Box).v}`;
}

console.log(await all());
const top = await getId();
const topBox = await getBox();
console.log(`${(top as int32) + 1} ${(topBox as Box).v + 1}`);
