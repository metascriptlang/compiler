// @stdout: counts 7 0 0 tuple! ar!ray! generic! ref!

struct Tracked { id: int32; text: string; }
struct Box<T> { value: T; }
let destroyed: int32 = 0;
let refDestroyed: int32 = 0;
function onDestroy(this p: Tracked): void { destroyed += p.id; }
class CountedRef {
	text: string;
	constructor(text: string) { this.text = text; }
	onDestroy(): void { refDestroyed += 1; }
}
function heap(text: string): string { return text + "!"; }
function value(p: Tracked): int32 { return p.id; }
function readonlyValue(readonly p: Tracked): int32 { return p.id; }
function refValue(ref p: Tracked): int32 { return p.id; }
function pointer(p: Ptr<Tracked>): int32 { return p.id; }
function borrowed(p: Borrow<Tracked>): int32 { return p.id; }
function cursor(p: Cursor<Tracked>): int32 { return p.id; }
function readonlyPointer(p: Readonly<Ptr<Tracked>>): int32 { return p.id; }
function reference(p: CountedRef): string { return p.text; }
function sized(p: string[2]): string { return p[0] + p[1]; }
function collect<T>(p: T): T[] { const values: T[] = []; values.push(p); return values; }
function borrowedReference(p: Borrow<CountedRef>): string { return p.text; }
when (c) {
	actor Ping { value(): int32 { return 7; } }
	struct ActorHolder { actor: Ping; }
	function actorValue(p: Ping): Ping { return p; }
	function actorRef(ref p: Ping): Ping { return p; }
	function actorHolder(p: ActorHolder): Ping { return p.actor; }
	function actorRoundtrip(): int32 {
		let p = new Ping();
		const holder: ActorHolder = { actor: actorValue(p) };
		const a = await actorValue(p).value();
		const b = await actorRef(p).value();
		const c = await actorHolder(holder).value();
		return a + b + c;
	}
}
function run(): void {
	let p: Tracked = { id: 1, text: "value!" };
	const r = new CountedRef("ref!");
	const read = value(p) + readonlyValue(p) + refValue(p) + pointer(p as Ptr<Tracked>)
		+ borrowed(p as Borrow<Tracked>) + cursor(p as Cursor<Tracked>) + readonlyPointer(p as Ptr<Tracked>);
	const tuples = collect<[string, int32]>([heap("tuple"), 2]);
	const fixed: string[2] = [heap("ar"), heap("ray")];
	const boxes = collect<Box<string>>({ value: heap("generic") });
	const refs = collect<CountedRef>(r);
	if (read != 7 || destroyed != 0 || refDestroyed != 0) throw new Error("formal reads changed ownership");
	if (tuples[0][0] != "tuple!" || tuples[0][1] != 2) throw new Error("tuple sink lost its payload");
	if (sized(fixed) != "ar!ray!") throw new Error("fixed-array formal changed its payload");
	if (boxes[0].value != "generic!") throw new Error("generic sink lost its payload");
	if (reference(refs[0]) != "ref!") throw new Error("reference sink lost its pointee");
	console.log(`counts ${read} ${destroyed} ${refDestroyed} ${tuples[0][0]} ${sized(fixed)} ${boxes[0].value} ${reference(refs[0])}`);
	if (borrowedReference(r as Borrow<CountedRef>) != "ref!") throw new Error("borrowed reference changed its pointee");
	const sizedValues = collect<string[2]>(fixed);
	if (sizedValues[0][0] != "ar!" || sizedValues[0][1] != "ray!") throw new Error("fixed-array sink lost its elements");
	when (c) { if (actorRoundtrip() != 21) throw new Error("actor formals lost their runtime handle"); }
}
run();
when (c) {
	if (destroyed != 1 || refDestroyed != 1) throw new Error("native formal ownership was not released exactly once");
}
