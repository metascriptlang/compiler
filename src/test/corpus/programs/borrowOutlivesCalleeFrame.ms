// @stdout: hello|str-1 top|str-2 | hello 5 abcdefghijkzz | 7 7
// @exit: 0
// note: a Borrow returned from a by-value first parameter reads the caller's argument, so it stays valid after the callee's frame is released and while the next argument's call runs; the raiser once released the parameter registers with the frame and read nil.

function self(s: string): Borrow<string> { return s; }
function cat(x: string, y: string): string { return x + "|" + y; }
function join(x: string, y: string): string { return x + y; }
function mkS(k: int32): string { return `str-${k}`; }
function nested(t: string): string { return cat(self(t), mkS(1)); }
function kept(t: string): string {
	const a = self(t);
	const z = join("abcdefghijk", "zz");
	return `${a} ${a.length} ${z}`;
}

console.log(nested("hello"), cat(self("top"), mkS(2)), "|", kept("hello"), "|", self(mkS(100)).length, self(`${mkS(200)}`).length);
