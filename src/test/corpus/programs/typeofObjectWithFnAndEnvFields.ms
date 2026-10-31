// @stdout: object function object function

interface Pair { fn: number; env: string; }
class Held { fn: number = 1; env: string = "b"; }

function kindOf(x: Pair | (() => number)): string { return typeof x === "function" ? "function" : "object"; }
function heldKind(x: Held | (() => string)): string { return typeof x === "function" ? "function" : "object"; }

const p: Pair = { fn: 1, env: "a" };
const captured = "c";
console.log(kindOf(p), kindOf((): number => 2), heldKind(new Held()), heldKind((): string => captured));
