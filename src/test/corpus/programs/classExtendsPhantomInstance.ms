// @stdout: bytes n=3 echo=7 read=3 is=true | wide n=5 echo=-2 read=5 | leaf n=4 k=2 read=4 echo=9 | gen n=6 echo=x read=6 | gen8 n=8 echo=1 read=8
// note: a class extending an instance of a generic class whose fields never name its type parameter, `Bytes extends Phantom<uint8>`, as a typed-array core does: the subclass gets the instance's fields and methods (whose signatures do name the parameter), passes where the instance is expected, and its `super(...)` runs the instance's constructor; variants with two instances of one generic side by side, two levels below the instance, and a generic `Gen<T> extends Phantom<T>`. Same output on C and JS.

class Phantom<T> {
	n: int32 = 0;
	constructor(n: int32) { this.n = n; }
	echo(x: T): T { return x; }
}

class Bytes extends Phantom<uint8> {
	constructor(n: int32) { super(n); }
}

class Wide extends Phantom<int32> {
	constructor(n: int32) { super(n); }
}

class Leaf extends Bytes {
	k: int32 = 2;
	constructor(n: int32) { super(n); }
}

class Gen<T> extends Phantom<T> {
	constructor(n: int32) { super(n); }
}

function readBytes(p: Phantom<uint8>): int32 { return p.n; }
function readWide(p: Phantom<int32>): int32 { return p.n; }
function readStr(p: Phantom<string>): int32 { return p.n; }

const b = new Bytes(3);
const w = new Wide(5);
const l = new Leaf(4);
const g = new Gen<string>(6);
const g8 = new Gen<uint8>(8);
console.log(`bytes n=${b.n} echo=${b.echo(7)} read=${readBytes(b)} is=${l instanceof Bytes} | wide n=${w.n} echo=${w.echo(-2)} read=${readWide(w)} | leaf n=${l.n} k=${l.k} read=${readBytes(l)} echo=${l.echo(9)} | gen n=${g.n} echo=${g.echo("x")} read=${readStr(g)} | gen8 n=${g8.n} echo=${g8.echo(1)} read=${readBytes(g8)}`);
