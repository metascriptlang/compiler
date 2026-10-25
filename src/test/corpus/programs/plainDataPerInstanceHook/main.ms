// @stdout: plain box=1,0 holder=1,0 cell=1,0
// note: a hook declared for one instance of a generic type belongs to that instance only, so isPlainData<T>() still answers true for every other instance, for a struct that holds one, and for an instance of a generic type from another module. Same output on every backend.
import { isPlainData } from "std/typetraits";
import { Cell } from "./lib";

struct Box<T> { v: T; }
struct Holder<T> { b: Box<T>; }

function onDestroy(this x: Box<int32>): void {
	console.log("box " + x.v.toString());
}

function bit(b: boolean): string {
	return b ? "1" : "0";
}

console.log("plain box=" + bit(isPlainData<Box<uint8>>()) + "," + bit(isPlainData<Box<int32>>())
	+ " holder=" + bit(isPlainData<Holder<uint8>>()) + "," + bit(isPlainData<Holder<int32>>())
	+ " cell=" + bit(isPlainData<Cell<uint8>>()) + "," + bit(isPlainData<Cell<int32>>()));
