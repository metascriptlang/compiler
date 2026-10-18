// Parity program — two object literals whose keys hold `__` stay two types. Before, the anonymous
// type name joined keys with `__`, so `{ x, s__y }` and `{ xs__, y }` both froze as
// `__anon2__xs__s__ys`: C built one struct for both and refused the second literal, and JS declared
// one stringify helper twice. The variant adds a third key and a boolean field type.
//
// @stdout: {"x":"a","s__y":"b"} {"xs__":"c","y":"d"} bc
// @stdout: {"p":true,"b__q":false,"r":true} {"pb__":false,"q":true,"r":false} false false

const a = { x: "a", s__y: "b" };
const b = { xs__: "c", y: "d" };
console.log(JSON.stringify(a) + " " + JSON.stringify(b) + " " + a.s__y + b.xs__);

const c = { p: true, b__q: false, r: true };
const d = { pb__: false, q: true, r: false };
console.log(JSON.stringify(c) + " " + JSON.stringify(d) + " " + c.b__q.toString() + " " + d.pb__.toString());
