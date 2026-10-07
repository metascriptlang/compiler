// @stdout: writers=3/2/9
// note: a view of a T[] reached through a value struct stays legal across ref writers that never resize the array (a scalar field write, a slot write, and a chain of both), and reads the written slots.

struct Pet { name: string; hunger: int32; }
struct World { pets: Pet[]; day: int32; }

function setDay(ref world: World, day: int32): void {
	world.day = day;
}

function feed(ref world: World, index: int32, amount: int32): void {
	world.pets[index].hunger = world.pets[index].hunger - amount;
}

function advance(ref world: World): void {
	setDay(world, world.day + 1);
	feed(world, 0, 1);
}

function refWriters(): string {
	let world: World = {
		pets: [
			{ name: "ant", hunger: 3 },
			{ name: "bee", hunger: 5 },
			{ name: "cat", hunger: 7 },
		],
		day: 4,
	};
	const view: Span<Pet> = world.pets;
	setDay(world, 8);
	feed(world, 2, 4);
	advance(world);
	return `${view[2].hunger}/${view[0].hunger}/${world.day}`;
}

console.log(`writers=${refWriters()}`);
