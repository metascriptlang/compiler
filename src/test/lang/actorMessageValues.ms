struct MessagePoint {
	x: int32;
	y: int32;
}

struct MessageFrame {
	point: MessagePoint;
	label: string;
}

actor ValueMailbox {
	private last: MessagePoint = { x: 0, y: 0 };
	private nested: MessageFrame = {
		point: { x: 0, y: 0 },
		label: "",
	};

	put(point: MessagePoint): void { this.last = point; }
	putNested(byte: MessageFrame): void { this.nested = byte; }
	sum(): int32 { return this.last.x + this.last.y; }
	nestedSum(): int32 {
		return this.nested.point.x + this.nested.point.y +
			(this.nested.label.length as int32);
	}
	pause(): void { await sleepAsync(1); }
	read(point: MessagePoint): int32 { return point.x + point.y; }
	label(text: string, count: int32): string { return text + count.toString(); }
}

test "actor send snapshots a value before the sender mutates it" {
	const mailbox = new ValueMailbox();
	let point: MessagePoint = { x: 1, y: 2 };
	mailbox.put(point);
	point.x = 100;
	assert await mailbox.sum() == 3;
	assert point.x == 100;
}

test "actor send snapshots nested value fields" {
	const mailbox = new ValueMailbox();
	let frame: MessageFrame = {
		point: { x: 3, y: 4 },
		label: "ok",
	};
	mailbox.putNested(frame);
	frame.point.x = 100;
	frame.label = "changed";
	assert await mailbox.nestedSum() == 9;
	assert frame.point.x == 100;
}

test "actor call snapshots a value before waiting behind a suspended send" {
	const mailbox = new ValueMailbox();
	let point: MessagePoint = { x: 5, y: 6 };
	mailbox.pause();
	const pending = mailbox.read(point);
	point.y = 100;
	assert await pending == 11;
	assert point.y == 100;
}

test "actor scalar and string arguments keep their value semantics" {
	const mailbox = new ValueMailbox();
	assert await mailbox.label("value", 7) == "value7";
}
