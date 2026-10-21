// @xfail(raiser): raiser runtime error: cannot compile 'new' here: no matching constructor in the Raiser function table
// @stdout: send nx nx
// @stdout: call ny-7 ny
// @stdout: done
// @ledger-slack(Keeper) 1
// ledger-slack reason: its actors are never stopped, so they and what they own are still live at exit
// note: A struct passed to an actor method is copied into the message: the caller keeps its own
// value. Before, the boxing of a struct argument moved it out of the caller's variable, so the
// caller read an empty string after the send (`send nx ` on C, DRC and ORC, while JS printed the
// value).

struct Pt { a: int32; name: string; }

actor Keeper {
	last: string = "";
	put(p: Pt): void { this.last = p.name; }
	tagged(p: Pt): string { return p.name + "-" + p.a.toString(); }
	get(): string { return this.last; }
}

function grown(base: string, tail: string): string {
	return base + tail;
}

async function main(): Promise<void> {
	const k = new Keeper();
	const v: Pt = { a: 4, name: grown("n", "x") };
	k.put(v);
	const got = await k.get();
	console.log(`send ${got} ${v.name}`);
	const w: Pt = { a: 7, name: grown("n", "y") };
	const t = await k.tagged(w);
	console.log(`call ${t} ${w.name}`);
}

await main();
console.log("done");
