// @stdout: zy zy|zy! zy! zy!|4 4 5
// note: a binding a module-level destructuring declares is a module global: a closure and a function read the one location, and a write from a function reaches both (an array pattern and an object pattern). Before, C copied the binding into the closure's env, so the function read an empty string and the closure missed the write, and the Raiser refused the read ("symbol has no declaration node").
interface Point { x: int32; y: int32; }

function origin(): Point { return { x: 3, y: 4 }; }

let [a, b] = ["x", "y"];
const f = () => a + b;
function g(): string { return a + b; }
function bump(): void { b = b + "!"; }

let { x, y } = origin();
const readX = () => x;
function moveX(): void { x = x + 1; }

a = "z";
const first = `${f()} ${g()}`;
bump();
const second = `${f()} ${g()} ${a}${b}`;
moveX();
console.log(`${first}|${second}|${readX()} ${x} ${x + y - 3}`);
