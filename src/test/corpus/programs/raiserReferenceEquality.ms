// @stdout: true false true false true false true false y n true false true false
// @exit: 0
// note: === and !== on a class, interface, unknown or generic operand compare by identity on every target, with the operands in the reference register file on the raiser.

class Key { name: string; constructor(name: string) { this.name = name; } }
interface Named { name: string; }
function same(a: unknown, b: Key): boolean { return a === b; }
function differ(a: Key, b: unknown): boolean { return a !== b; }
function both(a: unknown, b: unknown): boolean { return a == b; }
function viaIface(a: Named, b: unknown): boolean { return a === b; }
function branch(a: unknown, b: Key): string { if (a === b) return "y"; return "n"; }
function generic<T>(a: T, b: T): boolean { return a === b; }
const k = new Key("k");
const j = new Key("k");
console.log(same(k, k), same(j, k), differ(k, j), differ(k, k), both(k, k), both(k, j), viaIface(k, k), viaIface(j, k), branch(k, k), branch(j, k), generic(k, k), generic(k, j), generic(3, 3), generic("a", "b"));
