// @stdout: name a|tag b2|name c|wrapped d
// An actor method takes a value-layout argument by address through its generated proxy, so
// inferring sink there would turn `move m` into a refused copy. A union with a string payload,
// moved at the top of a routine and one block deeper, and a struct holding one.
import { stop, ExitReason } from "std/actor";

enum Kind { Name, Tag }
type Note = match (kind: Kind) {
	Kind.Name => { name: string },
	Kind.Tag => { tag: string; n: int32 },
};
struct Wrapped { note: Note; }

actor Keeper {
	private log: string[] = [];
	note(m: Note): void {
		if (m.kind === Kind.Name) { this.log.push(`name ${m.name}`); return; }
		if (m.kind === Kind.Tag) { this.log.push(`tag ${m.tag}${m.n}`); }
	}
	wrapped(w: Wrapped): void {
		if (w.note.kind === Kind.Name) this.log.push(`wrapped ${w.note.name}`);
	}
	lines(): string {
		let all = this.log.join("|");
		return move all;
	}
}

const keeper = new Keeper();
function sendMoved(to: Keeper): void {
	let a: Note = { kind: Kind.Name, name: "a" };
	to.note(move a);
	let b: Note = { kind: Kind.Tag, tag: "b", n: 2 };
	to.note(move b);
}
sendMoved(keeper);
function sendNested(to: Keeper, name: string): void {
	if (name.length > 0) {
		let c: Note = { kind: Kind.Name, name };
		to.note(move c);
	}
}
sendNested(keeper, "c");
function sendWrapped(to: Keeper): void {
	let w: Wrapped = { note: { kind: Kind.Name, name: "d" } };
	to.wrapped(move w);
}
sendWrapped(keeper);
const sent = await keeper.lines();
console.log(`${sent}`);
stop(keeper.pid, ExitReason.Normal);
