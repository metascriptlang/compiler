// @stdout: 1 9 9 8 0.25 50
// note: fields and parameters named near, far, linux, unix and i386 compile on C (codegen-c-7: windows.h defines near and far empty, GNU-mode compilers predefine linux, unix and i386).

interface Span {
	near: int32;
	far: int32;
	linux: int32;
	unix: int32;
	i386: int32;
}
class Clip {
	near: float64 = 0.5;
	far: float64 = 100;
	constructor(near: float64, far: float64) { this.near = near; this.far = far; }
}
function depth(near: int32, far: int32): int32 { return far - near; }
function run(): void {
	const s: Span = { near: 1, far: 9, linux: 2, unix: 3, i386: 4 };
	const c = new Clip(0.25, 50);
	console.log(s.near, s.far, s.linux + s.unix + s.i386, depth(s.near, s.far), c.near, c.far);
}
run();
