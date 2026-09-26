// @stdout: s:a n0 g0 g2|n0 s:b
// @xfail(raiser): Raiser does not lower rest parameters; any call to a rest function reads a nil array
function f(s: string): string { return "s:" + s; }
function f(...xs: int32[]): string { return "n" + xs.length.toString(); }
function g(...xs: int32[]): string { return "g" + xs.length.toString(); }
function h(...xs: int32[]): string { return "n" + xs.length.toString(); }
function h(s: string): string { return "s:" + s; }
console.log(f("a") + " " + f() + " " + g() + " " + g(1, 2) + "|" + h() + " " + h("b"));
