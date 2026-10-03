// @stdout: program=198535 named=198535 joined=198535 key=7,14 weight=30 nested=20 chain=18 local=42
// note: calls to @comptime functions are evaluated while compiling — imported and same-module, with a literal, a const name, a joined const array, a struct result, an enum argument, a nested call, a @comptime function calling another, and a call inside a function body; same output on every backend.

import { PROGRAM, Kind, Key, digitSum, keyOf, weight, twice, sumOfTwice } from "./lib/ids";

const NAME = "2222";
const PARTS: string[] = ["22", "22"];
const NAMED: uint64 = digitSum(NAME);
const JOINED: uint64 = digitSum(PARTS[0] + PARTS[1]);
const KEY: Key = keyOf(7);
const WEIGHT: int32 = weight(Kind.Large, 3);
const NESTED: int32 = twice(twice(5));
const CHAIN: int32 = sumOfTwice(4);

function local(): int32 {
	const value = twice(21);
	return value;
}

function main(): void {
	console.log(`program=${PROGRAM} named=${NAMED} joined=${JOINED} key=${KEY.a},${KEY.b} weight=${WEIGHT} nested=${NESTED} chain=${CHAIN} local=${local()}`);
}

main();
