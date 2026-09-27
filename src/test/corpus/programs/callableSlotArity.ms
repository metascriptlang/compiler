// @stdout: calls 6 k s values 42 hello 5 3 42 7 hi 42 8 1 true 2

interface Box<T> { value: T; }
interface Event { kind: string; value: string; }
interface Slot { handler: (event: Event) => void; }
interface Factory { make: () => int32; }
class Item { n: int32; constructor() { this.n = 1; } }

function call(callback: () => int32): int32 { return callback(); }
function fire(callback: (event: Event) => void): void { callback({ kind: "k", value: "v" }); }
function firePair(callback: (a: string, b: int32) => void): void { callback("s", 42); }
function each(callback: (x: int32) => int32): int32 { return callback(1); }
function makeItem(): Item { return new Item(); }
let registered: () => Item | null = (): Item | null => null;
function register(callback: () => Item | null): void { registered = callback; }

let calls: int32 = 0;
const nothing = (): void => { calls += 1; };
const integer = (): int32 => 42;
const text = (): string => "hello";
const generic = (): Box<int32> => ({ value: 5 });
const array = (): int32[] => [1, 2, 3];
const factory: Factory = { make: (): int32 => 7 };
const inferred = () => "hi";
const parameter = (x: int32): int32 => x * 2;
const slot: Slot = { handler: () => { calls += 1; } };
const slots: Slot[] = [{ handler: (): void => { calls += 1; } }];
let seen = "";
nothing();
slot.handler({ kind: "a", value: "b" });
slots[0].handler({ kind: "c", value: "d" });
fire(() => { calls += 1; });
fire(event => { calls += 1; seen = event.kind; });
let pair = "";
firePair(a => { calls += 1; pair = a; });
register(makeItem);
const item = registered();
console.log(`calls ${calls} ${seen} ${pair} values ${integer()} ${text()} ${generic().value} ${array().length} ${call((): int32 => 42)} ${factory.make()} ${inferred()} ${parameter(21)} ${call(() => 8)} ${item !== null ? item.n : -1} ${item !== null} ${each(x => x + 1)}`);
