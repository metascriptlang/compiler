// @stdout: decl=1,1 array=1 object=1 ternary=1 generic=1 viaFunction=hit 3 union=A1 value=7
// note: a variable narrowed to null by `x = null`, then set by a closure or a called function, is read into new storage (an unannotated const/let, an array or object literal, a ternary, a generic argument) through the type it stores, so C reads the value it holds. Same output on every backend.

class Box { v: int32 = 1; }
class Tag { a: int32 = 1; }
class Other { b: int32 = 2; }

function count(b: Box | null): int32 { return b === null ? -1 : b.v; }
function run(fn: () => void): void { fn(); }
function id<T>(x: T): T { return x; }

let target: Box | null = null;
function probe(): void { target = new Box(); target.v = 3; }

function viaFunction(): string {
	target = null;
	probe();
	const node = target;
	target = null;
	return node !== null ? "hit " + node.v.toString() : "miss";
}

function main(): void {
	let owner: Box | null = null;
	run(() => { owner = new Box(); });
	const c = owner;
	let l = owner;
	const arr = [owner];
	const rec = { b: owner };
	const flag = c !== null;
	const t = flag ? owner : null;
	const g = id(owner);
	let u: Tag | Other | null = new Other();
	run(() => { u = null; });
	let uText = "none";
	if (u === null) {
		run(() => { u = new Tag(); });
		const o = u;
		uText = o === null ? "null" : (o instanceof Tag ? "A" + o.a.toString() : "B");
	}
	let n: int32 | null = null;
	run(() => { n = 7; });
	const m = n;
	console.log(`decl=${count(c)},${count(l)} array=${count(arr[0])} object=${count(rec.b)} ternary=${count(t)} generic=${count(g)}`
		+ ` viaFunction=${viaFunction()} union=${uText} value=${m === null ? "null" : m.toString()}`);
}

main();
