// @stdout: true true|2 1|3 2 1
// @exit: 0
// note: a branded array (Buffer) held across an await lives in the async frame under its declared brand, and its length still reads the element count: a local Buffer inside an awaited call's argument, a Buffer field of a struct local, a string beside it, and a slice of the frame's Buffer.

struct Packet {
	body: Buffer;
	label: string;
}

async function check(d: Buffer): Promise<boolean> {
	return d.length > 0;
}

function flip(b: Buffer, i: int32): Buffer {
	const c = Buffer.copy(b);
	c[i] = (c[i] ^ 1) as uint8;
	return c;
}

async function count(d: Buffer): Promise<int32> {
	return d.length;
}

async function row(): Promise<string> {
	const blob = Buffer.fromString("0102", "hex");
	const opened = await check(blob);
	const tag = await check(flip(blob, blob.length - 1));
	const p: Packet = { body: Buffer.fromString("0a0b0c", "hex"), label: "ab" };
	const whole = await count(blob);
	const part = await count(blob.slice(0, blob.length - 1));
	const fromField = await count(p.body.slice(0, p.body.length));
	const label = await count(Buffer.fromString(p.label.slice(0, p.label.length - 1), "utf8"));
	return `${opened} ${tag}|${whole} ${part}|${fromField} ${p.label.length} ${label}`;
}

console.log(await row());
