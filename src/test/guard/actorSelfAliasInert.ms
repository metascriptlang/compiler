// nim-guard: an actor's dispatch never releases the actor's own state
//
// INVARIANT (varpartitions.nim potentialMutationViaArg :698-705, :764; computeCursors
//   :1017-1033 needs hasDestructor): a local passed to a routine is not a cursor,
//   so it owns a share only when its type has hooks. An actor is DRC-exempt
//   (classify.ms Ref arm), the analogue of a type without a destructor: its
//   runtime owns the state, and the dispatch's `_self` alias of it must be
//   RC-inert like the handler's `this`. NIM-REF: AN-1 (cursor inference, SAME),
//   AN-26 (a conversion forwards its operand, SAME).
//
// WHAT IT CATCHES: `_self` typed by actorLower with a Ref of a fresh struct that
//   lacked the actor symbol. Once cursor inference counted `_self` passed to an
//   `_impl` as a mutation, `_self` became an owned Ref: no share on the way in,
//   msDecref at the end of every dispatch. The second message freed the state
//   while its mailbox still ran (DOUBLE-DESTROY here, ASan heap-use-after-free in
//   msActorProcess on corpus 400). Shapes: void messages, an awaited reply that
//   reads `this`, a heap string field and a class field.
//
// RED MEANS: the dispatch or system-message self alias owns a share of the actor
//   again. Run /trace-nim on `_self` in actorLower.ms and its RcInfo in classify.ms.
// GUARD-JS

class Note { text: string; constructor(text: string) { this.text = text; } }

actor Tally {
	label: string = "";
	count: int32 = 0;
	setLabel(s: string): void { this.label = s; }
	bump(): void { this.count = this.count + 1; }
	report(): string { return this.label + ":" + String(this.count); }
}

actor Board {
	note: Note = new Note("");
	pin(text: string): void { this.note = new Note(text); }
	read(): string { return this.note.text; }
}

async function main(): Promise<void> {
	const t = new Tally();
	let base = "tally-";
	base = base + "heap";
	t.setLabel(base);
	for (let i = 0; i < 40; i = i + 1) { t.bump(); }
	const first = await t.report();
	for (let i = 0; i < 40; i = i + 1) { t.bump(); }
	const second = await t.report();

	const b = new Board();
	for (let i = 0; i < 20; i = i + 1) { b.pin("note-" + String(i)); }
	const last = await b.read();

	if (first == "tally-heap:40" && second == "tally-heap:80" && last == "note-19") {
		console.log("GUARD-OK");
	} else {
		console.log("GUARD-FAIL " + first + " " + second + " " + last);
		process.exit(1);
	}
}

main();
