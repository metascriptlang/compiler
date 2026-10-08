// @stdout: getter=3/5/cat around=5/7/12/3 chain=15/3 unrelated=2/25/bee slots=9/bug/6 crate=3/9/4
// note: a view of a T[] (and of a Vec inside a class) stays legal and reads the live slots across read-only getters, a struct that holds views, a nested chain of read-only calls, calls whose arguments cannot reach the viewed element type, and slot writes.

struct Pet { name: string; hunger: int32; }
struct World { pets: Pet[]; day: int32; }
struct Around { pets: Span<Pet>; base: int32; }
struct Tally { counts: int32[]; }
class Crate { cells: Vec<int32> = [1, 2, 3]; used: int32 = 3; }

function petCount(this world: World): int32 {
	return world.pets.length as int32;
}

function nextDay(this world: World): int32 {
	return world.day + 1;
}

function hungerAt(this around: Around, offset: int32): int32 {
	return around.pets[around.base + offset].hunger;
}

function reach(this around: Around): int32 {
	let sum = 0;
	for (let i = around.base; i < around.pets.length; i++) { sum += around.pets[i].hunger; }
	return sum;
}

function leaf(pets: Pet[], index: int32): int32 {
	return pets[index].hunger;
}

function middle(pets: Pet[]): int32 {
	return leaf(pets, 0) + leaf(pets, (pets.length as int32) - 1);
}

function outer(pets: Pet[]): int32 {
	return middle(pets) + leaf(pets, 1);
}

function bumpTally(ref tally: Tally): void {
	tally.counts.push(1);
}

function clamp(value: int32, high: int32): int32 {
	return value > high ? high : value;
}

function slotsUsed(this crate: Crate): int32 {
	return crate.used;
}

function makeWorld(): World {
	return {
		pets: [
			{ name: "ant", hunger: 3 },
			{ name: "bee", hunger: 5 },
			{ name: "cat", hunger: 7 },
		],
		day: 4,
	};
}

function readOnlyGetters(): string {
	let world = makeWorld();
	const view: Span<Pet> = world.pets;
	const count = world.petCount();
	const tomorrow = world.nextDay();
	return `${count}/${tomorrow}/${view[2].name}`;
}

function structHoldingViews(): string {
	let world = makeWorld();
	const around: Around = { pets: world.pets, base: 1 };
	const near = around.hungerAt(0);
	const far = around.hungerAt(1);
	const count = world.petCount();
	return `${near}/${far}/${around.reach()}/${count}`;
}

function nestedChain(): string {
	let world = makeWorld();
	const view: Span<Pet> = world.pets;
	const sum = outer(world.pets);
	return `${sum}/${view[0].hunger}`;
}

function unrelatedArguments(): string {
	let world = makeWorld();
	const view: Span<Pet> = world.pets;
	let tally: Tally = { counts: [] };
	bumpTally(tally);
	bumpTally(tally);
	const clipped = clamp(40, 25);
	return `${tally.counts.length}/${clipped}/${view[1].name}`;
}

function slotWrites(): string {
	let world = makeWorld();
	const view: Span<Pet> = world.pets;
	world.pets[0].hunger = 9;
	world.pets[1] = { name: "bug", hunger: 6 };
	return `${view[0].hunger}/${view[1].name}/${view[1].hunger}`;
}

function vecInClass(): string {
	const crate = new Crate();
	const view: Span<int32> = crate.cells;
	const taken = crate.slotsUsed();
	crate.cells[1] = 9;
	crate.used = 4;
	return `${taken}/${view[1]}/${crate.used}`;
}

console.log(
	`getter=${readOnlyGetters()} around=${structHoldingViews()} chain=${nestedChain()} ` +
	`unrelated=${unrelatedArguments()} slots=${slotWrites()} crate=${vecInClass()}`,
);
