// @stdout: send 1 2
// @stdout: call 6 5
// @stdout: stored 3 100
// @stdout: nested 7 9 tag-a
// @stdout: nested caller 70 90 tag-b
// @stdout: nested stored 7 9 tag-a

struct Point { x: int32; y: int32; }
struct Segment { from: Point; to: Point; tag: string; }

actor Sink {
	private sum: int32 = 0;
	private last: Point = { x: 0, y: 0 };
	private seg: Segment = { from: { x: 0, y: 0 }, to: { x: 0, y: 0 }, tag: "" };
	take(p: Point): void { this.sum += p.x; }
	peek(p: Point): int32 { return p.x + this.sum; }
	plot(p: Point): void { this.last = p; }
	total(): int32 { return this.last.x + this.last.y; }
	keep(s: Segment): void { this.seg = s; }
	seen(): string { return `${this.seg.from.x} ${this.seg.to.y} ${this.seg.tag}`; }
}

async function run(): Promise<void> {
	const sink = new Sink();

	const a: Point = { x: 1, y: 2 };
	sink.take(a);
	console.log("send", a.x, a.y);

	const b: Point = { x: 5, y: 6 };
	console.log("call", await sink.peek(b), b.x);

	let p: Point = { x: 1, y: 2 };
	sink.plot(p);
	p.x = 100;
	console.log("stored", await sink.total(), p.x);

	let s: Segment = { from: { x: 7, y: 8 }, to: { x: 8, y: 9 }, tag: "tag-a" };
	sink.keep(s);
	console.log("nested", s.from.x, s.to.y, s.tag);
	s.from.x = 70;
	s.to.y = 90;
	s.tag = "tag-b";
	console.log("nested caller", s.from.x, s.to.y, s.tag);
	console.log("nested stored", await sink.seen());
}
await run();
