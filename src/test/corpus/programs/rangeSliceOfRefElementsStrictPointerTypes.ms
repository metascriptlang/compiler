// @stdout: class 5|anon 3|ptr 2 true|ints 5|empty 0|done

@passC("-Werror=incompatible-pointer-types");

class Pet { a: int32; constructor(a: int32) { this.a = a; } }
type Laid = { x: float32 };

function sumPets(v: Span<Pet>): int32 { let s = 0; for (let i = 0; i < (v.length as int32); i++) s += v[i].a; return s; }
function sumLaid(v: Readonly<Span<Laid>>): float32 { let s: float32 = 0; for (let i = 0; i < (v.length as int32); i++) s = s + v[i].x; return s; }
function sumInts(v: Span<int32>): int32 { let s = 0; for (const n of v) s += n; return s; }

function run(): void {
	const pets: Pet[] = [new Pet(1), new Pet(2), new Pet(3)];
	const ls: Laid[] = [{ x: 1 }, { x: 2 }, { x: 4 }];
	const ints: int32[] = [1, 2, 3, 4];
	const slots: Ptr<Pet>[] = [pets[0] as Ptr<Pet>, pets[1] as Ptr<Pet>, pets[2] as Ptr<Pet>];
	const none: Pet[] = [];
	const view = slots[1..3] as Span<Ptr<Pet>>;
	console.log(`class ${sumPets(pets[1..3])}|anon ${sumLaid(ls[0..2])}|ptr ${view.length} ${view[0] == slots[1]}|ints ${sumInts(ints[1..3]) + sumInts(ints[0..0])}|empty ${sumPets(none[0..0])}|done`);
}
run();
