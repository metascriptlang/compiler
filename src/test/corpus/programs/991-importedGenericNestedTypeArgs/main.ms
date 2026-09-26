// @stdout: nest n | third t | deep d
import { Holder } from "./holder";
import { ABox } from "./abox";

class Box<T> {
	v: T;
	constructor(v: T) { this.v = v; }
}

const held = new Holder<Box<string>>(new Box<string>("n"));
const third = new Holder<ABox<string>>(new ABox<string>("t"));
const deep = new Holder<Box<ABox<string>>>(new Box<ABox<string>>(new ABox<string>("d")));
console.log(`nest ${held.h.v} | third ${third.h.a} | deep ${deep.h.v.a}`);
