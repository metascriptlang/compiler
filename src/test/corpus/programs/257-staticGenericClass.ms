// note: static method of a generic class must monomorphize per instantiation —
// T binds from an explicit <int32>, the annotated destination, or plain arg
// inference; two value types prove the instances coexist. Was: checker passed,
// C link failed on the unmonomorphized call name. Guard: fixedbugs/bug128.
class Box<T> {
	v: T;
	constructor(x: T) { this.v = x; }
	static make(x: T): Box<T> { return new Box<T>(x); }
}

function main(): void {
	const a = Box.make<int32>(5);
	console.log("explicit=" + a.v);
	const b: Box<int32> = Box.make(7);
	console.log("annotated=" + b.v);
	const c = Box.make<string>("s");
	console.log("string=" + c.v);
}
main();
