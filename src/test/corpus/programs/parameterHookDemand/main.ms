// @skip-js: user lifecycle counters require the native lifecycle backend
// @skip-raiser: user lifecycle counters require the native lifecycle backend
// @stdout: released 1 1

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
extern function append<T>(this a: T[], sink p: T): void from "&msGenericArrayPush";
function sized(p: string[2]): string { return p[0] + p[1]; }
function collect<T>(p: T): T[] { const values: T[] = []; values.append(p); return values; }
function borrowedReference(p: Borrow<CountedRef>): string { return p.text; }
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
function run(): void {
	let p: Tracked = { id: 1, text: "value!" };
	const r = new CountedRef("ref!");
	const read = value(p) + readonlyValue(p) + refValue(p) + pointer(p as Ptr<Tracked>)
		+ borrowed(p as Borrow<Tracked>) + cursor(p as Cursor<Tracked>) + readonlyPointer(p as Ptr<Tracked>);
	const tuples = collect<[string, int32]>([heap("tuple"), 2]);
	const fixed: string[2] = [heap("ar"), heap("ray")];
	const boxes = collect<Box<string>>({ value: heap("generic") });
	const refs = collect<CountedRef>(r);
	assert read == 7;
	assert destroyed == 0;
	assert refDestroyed == 0;
	assert tuples[0][0] == "tuple!";
	assert tuples[0][1] == 2;
	assert sized(fixed) == "ar!ray!";
	assert boxes[0].value == "generic!";
	assert reference(refs[0]) == "ref!";
	console.log(`counts ${read} ${destroyed} ${refDestroyed} ${tuples[0][0]} ${sized(fixed)} ${boxes[0].value} ${reference(refs[0])}`);
	assert borrowedReference(r as Borrow<CountedRef>) == "ref!";
	const sizedValues = collect<string[2]>(fixed);
	assert sizedValues[0][0] == "ar!";
	assert sizedValues[0][1] == "ray!";
	assert actorRoundtrip() == 21;
}
run();
assert destroyed == 1;
assert refDestroyed == 1;
console.log(`released ${destroyed} ${refDestroyed}`);
