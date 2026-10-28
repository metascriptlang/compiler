// @stdout: plain 11 true | named 12 true | span 9
struct Pet { a: uint32; b: uint8; }
struct Named { name: string; n: int32; }
function petAt(values: Pet[]): Ptr<Pet> { return values[1] as Ptr<Pet>; }
function namedAt(values: Named[]): Ptr<Named> { return values[1] as Ptr<Named>; }
function first(view: Span<Pet>): Ptr<Pet> { return view as Ptr<Pet>; }

function run(): void {
	let pets: Pet[] = [{ a: 1, b: 2 }, { a: 3, b: 4 }];
	const pet = petAt(pets);
	pet[].a = 11;
	let items: Named[] = [{ name: "a", n: 1 }, { name: "b", n: 3 }];
	const named = namedAt(items);
	named[].n = 12;
	first(pets)[].a = 9;
	console.log(`plain ${pets[1].a} ${pet == (pets[1] as Ptr<Pet>)} | named ${items[1].n} ${named == (items[1] as Ptr<Named>)} | span ${pets[0].a}`);
}
run();
