// @stdout: holder 0 1 named=true opt 2 3 present=true
// @stdout: three top|v-1|v-2 block in|v-4
// @exit: 0
// note: a register read after the statement that wrote it keeps its value while later statements reuse temps: the value a `return` inside the cleanup region of a function with a destroyed local leaves for the Ret that re-runs after the cleanup, and the argument slot a borrow of a by-value first parameter reads.

struct Named { name: string }
struct Pt { x: int32, y: int32 }
struct Holder { v: Named | int32, n: int32 }
struct Opt { p: Pt | null, n: int32 }

function holder(k: int32, s: string): Holder { return { v: k == 0 ? { name: s } : k, n: k }; }
function opt(k: int32): Opt { return { p: k == 2 ? { x: k, y: 1 } : null, n: k }; }

function self(s: string): Borrow<string> { return s; }
function mk(k: int32): string { return `v-${k}`; }
function cat(x: string, y: string): string { return x + "|" + y; }
function cat3(x: string, y: string, z: string): string { return x + "|" + y + "|" + z; }
function three(t: string): string { return cat3(self(t), mk(1), mk(2)); }
function inBlock(t: string, k: int32): string {
	let out = "";
	if (k > 0) { out = cat(self(t), mk(k)); }
	return out;
}

const named: Named = { name: "ab" };
console.log(`holder ${holder(0, "ab").n} ${holder(1, "").n} named=${holder(0, "ab").v == named} opt ${opt(2).n} ${opt(3).n} present=${opt(2).p != null}`);
console.log(`three ${three("top")} block ${inBlock("in", 4)}`);
