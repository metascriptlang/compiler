import { Gauge as GaugeA } from "./fixtures/staticReceiverA";
import { Gauge as GaugeB } from "./fixtures/staticReceiverB";

test "a static extension binds to the type its receiver names" {
	assert GaugeA.make() == 11;
	assert GaugeB.make() == 22;
}

test "prelude statics keep resolving through their own types" {
	assert Math.floor(3.7) == 3.0;
	assert Number.isInteger(5);
}

struct Cell { n: int32; }

function make(this typeof Cell, n: int32): Cell { return { n: n }; }

function applyCell(f: (n: int32) => Cell, n: int32): int32 { return f(n).n; }

test "a static extension read as a value names its routine" {
	assert applyCell(Cell.make, 5) == 5;
	const made = Cell.make;
	assert made(6).n == 6;
}

function applyNum(f: (x: number) => number, x: number): number { return f(x); }

test "a prelude static read as a value calls the built-in" {
	assert applyNum(Math.floor, 3.7) == 3.0;
	assert applyNum(Math.abs, -2.5) == 2.5;
	const isInt = Number.isInteger;
	assert isInt(4);
	assert !isInt(4.5);
}

interface Port {
	open: (n: int32) => int32;
	size: int32;
}

function open(this typeof Port, n: int32): Port { return { open: (k: int32): int32 => k + n, size: n }; }

test "a static extension call on its type skips the instance field of its name" {
	const p = Port.open(3);
	assert p.open(4) == 7;
	assert p.size == 3;
}
