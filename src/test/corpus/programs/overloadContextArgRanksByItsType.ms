// @stdout: function void value value void value
// @stdout: method void value value void value
// @stdout: extension void value value
// @stdout: seen 7
// note: a callback argument whose type depends on the overload ranks the overloads once it is
// typed: a block that returns nothing picks the void-callback overload over a generic `U` one in
// either declaration order, and a callback that returns a value picks the generic one, for a
// function, a class method and an extension method.

class Box<T> {
	v: T;
	constructor(v: T) { this.v = v; }
	on(cb: (v: T) => void): string { cb(this.v); return "void"; }
	on<U>(cb: (v: T) => U): string { cb(this.v); return "value"; }
	rev<U>(cb: (v: T) => U): string { cb(this.v); return "value"; }
	rev(cb: (v: T) => void): string { cb(this.v); return "void"; }
}

class Cell { n: int32 = 1; }
function at(this c: Cell, cb: (v: int32) => void): string { cb(c.n); return "void"; }
function at<U>(this c: Cell, cb: (v: int32) => U): string { cb(c.n); return "value"; }

function on(cb: (v: int32) => void): string { cb(1); return "void"; }
function on<U>(cb: (v: int32) => U): string { cb(1); return "value"; }
function rev<U>(cb: (v: int32) => U): string { cb(1); return "value"; }
function rev(cb: (v: int32) => void): string { cb(1); return "void"; }

let seen: int32 = 0;
console.log(`function ${on((v) => { seen += v; })} ${on((v) => v + 1)} ${on((v) => { return v + 1; })} ${rev((v) => { seen += v; })} ${rev((v) => v + 1)}`);
const box = new Box<int32>(2);
console.log(`method ${box.on((v) => { seen += v; })} ${box.on((v) => v + 1)} ${box.on((v) => { return v + 1; })} ${box.rev((v) => { seen += v; })} ${box.rev((v) => v + 1)}`);
const cell = new Cell();
console.log(`extension ${cell.at((v) => { seen += v; })} ${cell.at((v) => v + 1)} ${cell.at((v) => { return v + 1; })}`);
console.log(`seen ${seen}`);
