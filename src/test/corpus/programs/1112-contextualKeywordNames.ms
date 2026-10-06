// Parity program — a contextual keyword is a name wherever its construct cannot
// start: a statement that begins with it reads it as an identifier, while the
// construct itself still parses when its own next token follows.
//
// @stdout: a,b,2,3,1,4,call,5,6
// @exit: 0

function pick(flag: boolean): string {
	let test = "";
	if (flag) { test = "a"; }
	return test;
}

function shadowed(): string {
	let type = "b";
	type += "";
	return type;
}

class Holder { struct: int32 = 1; }

function counts(): int32[] {
	let defer = 1;
	defer += 1;
	let assert = 2;
	assert++;
	const actor = new Holder();
	actor.struct;
	let unreachable: int32[] = [0];
	unreachable[0] = 4;
	return [defer, assert, actor.struct, unreachable[0]];
}

function match(v: string): string { return v; }
function async(v: int32): int32 { return v + 1; }

function main(): void {
	const n = counts();
	const m = match("call");
	let move = 5;
	move;
	const k = async(5);
	console.log(`${pick(true)},${shadowed()},${n[0]},${n[1]},${n[2]},${n[3]},${m},${move},${k}`);
}

main();
