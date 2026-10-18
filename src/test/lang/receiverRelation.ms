type ReceiverBuffer = string;
type ReceiverCount = int32;

function shout(this s: string): string { return s + "!"; }

function orNil(this s: string | null): string { return s == null ? "nil" : "v:" + s; }

function twice(this n: number): number { return n * 2; }

function bufferSize(this b: ReceiverBuffer): number { return b.length; }

function countUp(this c: ReceiverCount): int32 { return c + 1; }

test "a string literal receives a string extension" {
	const lit = "abc";
	assert lit.shout() == "abc!";
	assert "inline".shout() == "inline!";
}

test "a value and null receive a nullable extension" {
	const s: string = "x";
	let m: string | null = null;
	assert s.orNil() == "v:x";
	assert m.orNil() == "nil";
}

test "an integer converts into a number receiver as a call would" {
	const k = 7;
	assert k.twice() == 14;
	assert (5).twice() == 10;
}

test "an alias of a primitive receives by its target" {
	const b: ReceiverBuffer = "hello";
	const c: ReceiverCount = 4;
	assert b.bufferSize() == 5;
	assert "zz".bufferSize() == 2;
	assert c.countUp() == 5;
}
