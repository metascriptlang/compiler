// @exit: 1
// @stdout: kept for the call 0
// @stdout: before 2
// @stdout: Error: onDestroy kept a reference to the Keeper it destroys
// @xfail(raiser): the Raiser VM runs no lifecycle hooks, so onDestroy never runs and the program exits 0
// @skip-js: onDestroy does not run on JS
// note: an onDestroy that stores `this` where it outlives the object stops the program when the object is freed, before that reference can dangle; a hook that holds `this` only for its own duration frees normally. Sibling: onDestroyKeepingThisInCycleStops (the collector's free path).

const kept: Keeper[] = [];

class Visitor {
	onDestroy(): void {
		const seen: Visitor[] = [this];
		console.log(`kept for the call ${seen.length - 1}`);
	}
}

class Keeper {
	id: int32;
	constructor(id: int32) { this.id = id; }
	onDestroy(): void {
		kept.push(this);
	}
}

function visit(): void {
	const v = new Visitor();
}

function keep(id: int32): void {
	const k = new Keeper(id);
	console.log(`before ${k.id}`);
}

visit();
keep(2);
console.log(`unreachable ${kept.length}`);
