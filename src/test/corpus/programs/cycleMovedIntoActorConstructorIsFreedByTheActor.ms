// @xfail(raiser): the Raiser VM has no actors and no per-thread cycle root sets, which this program pins
// @stdout: m
// @stdout: kept mo
// @stdout: kept mo
// @serial
// note: a struct holding a cyclic cell is moved into an actor's constructor. A temporary inside the constructor makes the cell a cycle root of the actor; what the constructor does not keep is dropped on the actor's root set, and what it keeps (the cell, through a field) is freed later by the actor. Before the fix the argument was destroyed after the constructor left the actor, on the caller's root set, and the free stopped with "M1 owner violation".

class Owner {
	back: Owner | null = null;
	tag: string = "o";
}

struct Module {
	name: string;
	owner: Owner;
}

function makeModule(): Module {
	const owner = new Owner();
	owner.back = owner;
	owner.back = null;
	return { name: "m", owner: owner };
}

actor Hub {
	name: string;
	constructor(module: Module) {
		const held: Owner[] = [module.owner];
		this.name = held[0].back === null ? module.name : "";
	}
	ping(): string {
		return this.name;
	}
}

actor Keeper {
	name: string;
	owner: Owner;
	constructor(module: Module) {
		const held: Owner[] = [module.owner];
		this.owner = module.owner;
		this.name = held[0].back === null ? module.name : "";
	}
	ping(): string {
		const keep: Owner[] = [this.owner, this.owner];
		this.owner.back = keep[1];
		this.owner.back = null;
		return this.name + this.owner.tag;
	}
}

async function main(): Promise<void> {
	const dropped: Module = { name: "m", owner: new Owner() };
	const hub = new Hub(move dropped);
	console.log(await hub.ping());
	const kept = makeModule();
	const keeper = new Keeper(move kept);
	console.log(`kept ${await keeper.ping()}`);
	console.log(`kept ${await keeper.ping()}`);
}

await main();
