// @stdout: 9 0 3 7 abc z 3 6 0
// note: an imported constructor or function with a rest parameter takes its trailing arguments packed, as a local one does: directly, empty, through the constructor a subclass inherits, through `super(...xs)` and through a forwarding spread. Same output on C, JS and the Raiser.
import { Many, Joined, sum } from "./lib";

class Sub extends Many { }
class Spread extends Many { constructor(...xs: int32[]) { super(...xs); } }
function fwd(...ys: int32[]): int32 { return sum(...ys); }

console.log(`${new Many(4, 5).total} ${new Many().total} ${new Sub(1, 2).total} ${new Spread(3, 4).total} ${new Joined("a", "b", "c").s} ${new Joined("z").s} ${sum(1, 2)} ${fwd(1, 2, 3)} ${fwd()}`);
