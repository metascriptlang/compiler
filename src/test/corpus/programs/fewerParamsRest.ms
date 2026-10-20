// @stdout: x+y z x:1 z:0 p+q+r true
// A function with a rest parameter fills a slot of fixed parameters: the slot's arguments
// from the rest position on become the rest array, and `===` sees the function itself.
function joinAll(...parts: string[]): string { return parts.join("+"); }
function head(first: string, ...rest: string[]): string { return first + ":" + rest.length; }
function two(f: (a: string, b: string) => string): string { return f("x", "y"); }
function one(f: (a: string) => string): string { return f("z"); }
const held: (a: string, b: string, c: string) => string = joinAll;
let seen: ((a: string, b: string) => string) | null = null;
function keep(f: (a: string, b: string) => string): boolean { seen = f; return seen === joinAll; }
console.log(two(joinAll), one(joinAll), two(head), one(head), held("p", "q", "r"), keep(joinAll));
