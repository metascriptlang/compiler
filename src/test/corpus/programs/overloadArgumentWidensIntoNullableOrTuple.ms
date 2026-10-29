// Parity program — an overloaded call takes a struct value into a `T | null`
// parameter and an array literal into a tuple parameter, as a call with one
// candidate does; the exact overload still outranks the widened one, for free
// functions, generic receivers and read-only receiver twins alike.
//
// @stdout: pos 1|str a|pair 1,0|pair 1,-1|exact|nullable|exact|nullable|box 2|view 2|box 3,4|view 3,4|box|view|box|view|shelf 1|view 1|shelf 5,6|view 5,6
// @exit: 0

struct Pos { x: int32; y: int32; }

function find(key: Pos | null): string { return key == null ? "none" : `pos ${key.x}`; }
function find(key: string): string { return `str ${key}`; }
function pair(key: [int32, int32 | null]): string { return `pair ${key[0]},${key[1] ?? -1}`; }
function pair(key: string): string { return `str ${key}`; }
function exact(key: Pos): string { return "exact"; }
function exact(key: Pos | null): string { return "nullable"; }
function tuple(key: [int32, int32]): string { return "exact"; }
function tuple(key: [int32, int32 | null]): string { return "nullable"; }

class Box<K> { k: K | null = null; }
function has<K>(this b: Box<K>, key: K): string { return "box"; }
function has<K>(this b: Readonly<Box<K>>, key: K): string { return "view"; }
function peek<K>(this b: Box<K>, key: Readonly<K>): string { return "box"; }
function peek<K>(this b: Readonly<Box<K>>, key: Readonly<K>): string { return "view"; }

class Shelf { n: int32 = 0; }
function seek(this s: Shelf, key: Pos | null): string { return key == null ? "shelf none" : `shelf ${key.x}`; }
function seek(this s: Readonly<Shelf>, key: Pos | null): string { return key == null ? "view none" : `view ${key.x}`; }
function slot(this s: Shelf, key: [int32, int32 | null]): string { return `shelf ${key[0]},${key[1] ?? -1}`; }
function slot(this s: Readonly<Shelf>, key: [int32, int32 | null]): string { return `view ${key[0]},${key[1] ?? -1}`; }

const out: string[] = [];
const p: Pos = { x: 1, y: 2 };
out.push(find(p));
out.push(find("a"));
out.push(pair([1, 0]));
out.push(pair([1, null]));
out.push(exact(p));
out.push(exact(null));
out.push(tuple([1, 0]));
out.push(tuple([1, null]));

const boxed = new Box<Pos | null>();
const q: Pos = { x: 2, y: 0 };
const boxedView: Readonly<Box<Pos | null>> = boxed;
out.push(`${boxed.has(q)} ${q.x}`);
out.push(`${boxedView.has(q)} ${q.x}`);
const tupled = new Box<[int32, int32 | null]>();
const tupledView: Readonly<Box<[int32, int32 | null]>> = tupled;
out.push(`${tupled.has([3, 4])} 3,4`);
out.push(`${tupledView.has([3, 4])} 3,4`);
out.push(`${boxed.peek(q)}|${boxedView.peek(q)}|${tupled.peek([3, 4])}|${tupledView.peek([3, 4])}`);

const shelf = new Shelf();
const shelfView: Readonly<Shelf> = shelf;
out.push(shelf.seek(p));
out.push(shelfView.seek(p));
out.push(shelf.slot([5, 6]));
out.push(shelfView.slot([5, 6]));
console.log(out.join("|"));
