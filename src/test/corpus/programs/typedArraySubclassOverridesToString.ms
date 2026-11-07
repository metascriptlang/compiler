// @stdout: buf:0-9-0 buf:0-9-0 0,0 0,0 0;0
// @exit: 0
// note: a subclass of a typed array overrides toString, and a call through the base type reaches the override, because each typed array declares its own join and toString as TypeScript's lib does.

class Buf extends Uint8Array {
	constructor(size: number) { super(size); }
	toString(): string { return "buf:" + this.join("-"); }
}
const b = new Buf(3);
b[1] = 9;
const u: Uint8Array = b;
const plain = new Uint8Array(2);
console.log(b.toString(), u.toString(), plain.toString(), `${plain}`, new Float64Array(2).join(";"));
