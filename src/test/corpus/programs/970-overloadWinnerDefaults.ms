// @stdout: x:10 21 21 w:7
// An overloaded call fills each missing argument from the default of the overload it chose
// (the reference's sigmatch `matches` fills from the candidate's own formals). The defaults came
// from the first-declared overload instead: `f(1)` summed 1 + 10 (the string overload's default)
// on both backends, and a string default reached an int32 parameter as `f(1, "zz")` in C.

function f(s: string, n: int32 = 10): string { return s + ":" + n.toString(); }
function f(a: int32, b: int32 = 20): string { return (a + b).toString(); }

function g(s: string, n: string = "zz"): string { return s + n; }
function g(a: int32, b: int32 = 20): string { return (a + b).toString(); }

function h(a: int32, b: int32 = 20): string { return (a + b).toString(); }
function h(s: string, w: int32 = 7): string { return s + ":" + w.toString(); }

console.log(f("x") + " " + f(1) + " " + g(1) + " " + h("w"));
