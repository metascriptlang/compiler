import { accountLayoutText } from "./accountCodecMacro";

enum Phase { Idle, Busy }
enum Delta { Down = -1, Up = 1 }
type Serial = distinct uint32;
struct Key { bytes: uint8[4]; }
struct Pair { left: uint16; right: Phase; }
struct Sample { key: Key; serial: Serial; delta: Delta; flags: BitSet<Phase>; pairs: Pair[2]; ratio: float32; on: boolean; }
struct Small { value: uint64; }

function textOf<T>(): string { return accountLayoutText<T>(); }

test "the layout text spells kind, offset, size and children of a struct" {
	assert textOf<Small>() == "{\"k\":\"struct\",\"z\":8,\"f\":[[\"value\",0,{\"k\":\"uint64\",\"z\":8}]]}";
	assert textOf<Key>() == "{\"k\":\"struct\",\"z\":4,\"f\":[[\"bytes\",0,{\"k\":\"array\",\"z\":4,\"n\":4,\"e\":{\"k\":\"uint8\",\"z\":1}}]]}";
}

test "the layout text unwraps distinct types, marks signed enums and nests arrays of structs" {
	const text = textOf<Sample>();
	assert text.includes("[\"serial\",4,{\"k\":\"uint32\",\"z\":4}]");
	assert text.includes("[\"delta\",8,{\"k\":\"enum\",\"z\":4,\"s\":1}]");
	assert text.includes("[\"flags\",12,{\"k\":\"bitset\",\"z\":1}]");
	assert text.includes("[\"pairs\",14,{\"k\":\"array\",\"z\":8,\"n\":2,\"e\":{\"k\":\"struct\",\"z\":4,\"f\":[[\"left\",0,{\"k\":\"uint16\",\"z\":2}],[\"right\",2,{\"k\":\"enum\",\"z\":1}]]}}]");
	assert text.includes("[\"ratio\",24,{\"k\":\"float32\",\"z\":4}],[\"on\",28,{\"k\":\"boolean\",\"z\":1}]");
}
