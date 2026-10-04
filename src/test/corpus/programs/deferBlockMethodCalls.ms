// @stdout: set=2 map=2 array=1,7 box=2 local=10 nested=inner,outer loop=3
// note: a `defer { … }` block is checked like any other block, so a method call inside it resolves to the method; before, the block went unchecked and C emitted `seen->add(7)` on a struct with no such member.
class Box {
	n: int32 = 0;
	bump(): void { this.n += 1; }
}
function setSize(): int32 {
	const seen = new Set<int32>();
	{
		defer { seen.add(7); }
		seen.add(1);
	}
	return seen.size as int32;
}
function mapSize(): int32 {
	const m = new Map<string, int32>();
	{
		defer { m.set("b", 2); }
		m.set("a", 1);
	}
	return m.size as int32;
}
function arrayItems(): string {
	const xs: int32[] = [];
	{
		defer { xs.push(7); }
		xs.push(1);
	}
	return `${xs[0]},${xs[1]}`;
}
function boxCount(): int32 {
	const b = new Box();
	{
		defer { b.bump(); }
		b.bump();
	}
	return b.n;
}
function localInDefer(): int32 {
	let total: int32 = 0;
	{
		defer {
			const ten: int32 = 10;
			total = total + ten;
		}
		total = 0;
	}
	return total;
}
function nested(): string {
	const order: string[] = [];
	{
		defer { order.push("outer"); }
		{
			defer { order.push("inner"); }
		}
	}
	return `${order[0]},${order[1]}`;
}
function loop(): int32 {
	const s = new Set<int32>();
	for (let i: int32 = 0; i < 3; i++) {
		defer { s.add(i); }
	}
	return s.size as int32;
}
console.log(`set=${setSize()} map=${mapSize()} array=${arrayItems()} box=${boxCount()} local=${localInDefer()} nested=${nested()} loop=${loop()}`);
