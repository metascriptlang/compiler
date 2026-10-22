// @stdout: fits-winner ok second second second second
// note: an argument is fitted to the parameter of the overload the call picked, not to the first overload declared: an int32 is not wrapped into the first overload's `int32 | string`, and a variant struct is not widened into the first overload's union, when a later overload wins on another argument; in either position. C passed the wrapped value to the winner's plain parameter and failed at clang.
struct Circle { r: int32; }
struct Square { side: int32; }
type Shape = Circle | Square;

function k(x: int32 | string, y: int32): string { return "first"; }
function k(x: int32, y: string): string { return "second " + x.toString(); }
function late(y: int32, x: int32 | string): string { return "first"; }
function late(y: string, x: int32): string { return "second " + x.toString(); }
function area(s: Shape, n: int32): string { return "first"; }
function area(c: Circle, label: string): string { return "second " + c.r.toString(); }

const i: int32 = 3;
const c: Circle = { r: 2 };
const out = [k(i, "s"), late("s", i), area(c, "x"), k(5, "t")];
console.log(out.join(" ") == "second 3 second 3 second 2 second 5" ? "fits-winner ok second second second second" : "fits-winner wrong " + out.join(" "));
