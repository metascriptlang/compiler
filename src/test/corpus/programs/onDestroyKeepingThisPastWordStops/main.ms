// @exit: 1
// @stdout: before 2
// @stdout: Error: onDestroy kept a reference to the Keeper it destroys
// @xfail(raiser): the Raiser VM runs no lifecycle hooks, so onDestroy never runs and the program exits 0
// @skip-js: onDestroy does not run on JS; `extern function` binds a C symbol
// note: the onDestroy check compares the object's count before and after the hook, at the
// count's full width. The helper adds 2^32 - 1 references in place of four billion real ones, so
// the one reference the hook keeps brings the count to 2^32; read as a 32-bit word that is 0 and
// the kept reference would go unnoticed. Sibling: onDestroyKeepingThisStops.

@include("./ffi.h");

extern function corpusKeepNearWord(p: Ptr<void>): void;

const kept: Keeper[] = [];

class Keeper {
	id: int32;
	constructor(id: int32) { this.id = id; }
	onDestroy(): void {
		corpusKeepNearWord(this as Ptr<void>);
		kept.push(this);
	}
}

function keep(id: int32): void {
	const k = new Keeper(id);
	console.log(`before ${k.id}`);
}

keep(2);
console.log(`unreachable ${kept.length}`);
