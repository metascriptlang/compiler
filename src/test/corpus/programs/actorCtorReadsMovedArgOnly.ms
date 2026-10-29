// @stdout: read nm
// @stdout: kept 2
// @stdout: plain 5
// @serial
// @ledger-slack(Holder) 1
// @ledger-slack(Keeper) 1
// @ledger-slack(Plains) 1
// @ledger-slack(Reader) 1
// ledger-slack reason: its actors are never stopped, so they and what they own are still live at exit
// note: an actor constructor that only reads a moved argument owns it, so its release runs over the actor's root set, not the creator's.

class Node {
	next: Node | null = null;
	label: string = "n";
}

struct Info {
	name: string;
	head: Node;
	call: (n: int32) => int32;
}

class Reader {
	label: string;
	constructor(info: Info) { this.label = info.head.label + info.name; }
}

actor Holder {
	reader: Reader;
	constructor(info: Info) { this.reader = new Reader(info); }
	label(): string { return this.reader.label; }
}

actor Keeper {
	info: Info;
	constructor(info: Info) { this.info = info; }
	call(n: int32): int32 { return this.info.call(n); }
}

class Plain {
	items: int32[] = [1, 2, 3, 4, 5];
}

actor Plains {
	plain: Plain;
	constructor(plain: Plain) { this.plain = plain.items.length > 0 ? plain : new Plain(); }
	count(): int32 { return this.plain.items.length; }
}

function makeInfo(): Info {
	const head = new Node();
	const box = new Node();
	box.next = head;
	const call = (n: int32): int32 => n + box.label.length as int32;
	return { name: "m", head: head, call: call };
}

function newHolder(sink info: Info): Holder {
	return new Holder(move info);
}

async function main(): Promise<void> {
	const holder = newHolder(makeInfo());
	console.log(`read ${await holder.label()}`);

	const keeper = new Keeper(move makeInfo());
	console.log(`kept ${await keeper.call(1)}`);

	const plain = new Plain();
	const plains = new Plains(move plain);
	console.log(`plain ${await plains.count()}`);
}

await main();
