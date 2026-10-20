// An `unknown` argument is no match for an overload whose formal is a generic
// container (`E[]`, `Vec<E>`, `Map<K2, V>`), so the generic `K` overload takes
// it, whichever order they are declared in and through a generic caller. A
// generic container formal still ranks above an `unknown` formal.
//
// @stdout: any any any any any|array vec map any|box box
// @exit: 0

class Box { n: int32 = 0; }
class Cell<T> {
	v: T;
	constructor(v: T) { this.v = v; }
}

function arrayFirst<E>(key: E[]): string { return "array"; }
function arrayFirst<K>(key: K): string { return "any"; }

function which<K>(key: K): string { return "any"; }
function which<E>(key: E[]): string { return "array"; }

function vecOrAny<K>(key: K): string { return "any"; }
function vecOrAny<E>(key: Vec<E>): string { return "vec"; }

function mapOrAny<K>(key: K): string { return "any"; }
function mapOrAny<K2, V>(key: Map<K2, V>): string { return "map"; }

function viaGeneric<K>(k: K): string { return which(k); }

function cellOrUnknown(x: unknown): string { return "unknown"; }
function cellOrUnknown<T>(x: Cell<T>): string { return "box"; }

function unknownOrCell<T>(x: Cell<T>): string { return "box"; }
function unknownOrCell(x: unknown): string { return "unknown"; }

const u: unknown = new Box();
const ns: int32[] = [1];
let v: Vec<int32> = [1];
const m = new Map<string, int32>();
const cell = new Cell<int32>(1);

console.log(`${which(u)} ${arrayFirst(u)} ${viaGeneric(u)} ${vecOrAny(u)} ${mapOrAny(u)}|${which(ns)} ${vecOrAny(v)} ${mapOrAny(m)} ${which(new Box())}|${cellOrUnknown(cell)} ${unknownOrCell(cell)}`);
