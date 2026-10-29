// @xfail(raiser): cannot compile 'new' here: no matching constructor in the Raiser function table

struct Point {
	x: int32;
	y: int32;
}

struct Frame {
	point: Point;
	label: string;
}

actor Mailbox {
	private last: Point = { x: 0, y: 0 };
	private nested: Frame = {
		point: { x: 0, y: 0 },
		label: "",
	};
	put(point: Point): void { this.last = point; }
	putNested(byte: Frame): void { this.nested = byte; }
	sum(): int32 { return this.last.x + this.last.y; }
	nestedSum(): int32 {
		return this.nested.point.x + this.nested.point.y +
			(this.nested.label.length as int32);
	}
	pause(): void { await sleepAsync(1); }
	read(point: Point): int32 { return point.x + point.y; }
	label(text: string, count: int32): string { return text + count.toString(); }
}

const mailbox = new Mailbox();
let point: Point = { x: 1, y: 2 };
mailbox.put(point);
point.x = 100;
const flat = await mailbox.sum();
let frame: Frame = { point: { x: 3, y: 4 }, label: "ok" };
mailbox.putNested(frame);
frame.point.x = 100;
frame.label = "changed";
const nested = await mailbox.nestedSum();
let queued: Point = { x: 5, y: 6 };
mailbox.pause();
const pending = mailbox.read(queued);
queued.y = 100;
const called = await pending;
const label = await mailbox.label("value", 7);
const result = `${flat} ${point.x}|${nested} ${frame.point.x} ${frame.label}|` +
	`${called} ${queued.y}|${label}`;
if (result != "3 100|9 100 changed|11 100|value7") {
	throw new Error("actor message did not snapshot its value before publication");
}
console.log(result);
