// @stdout: first-signature ok dog dog dog dog dog dog dog
// note: a call into a set of overload signatures takes the first signature its arguments fit, as TS does: a signature with a literal parameter type comes before the others whatever its place, a literal union and an alias of a literal type do not, and a fit without a numeric widening comes before one with it. Each call reads `bark()`, which only the Dog-returning signature allows; as a function and as an extension. Same output on C, JS and the Raiser.
class Animal { kind(): string { return "animal"; } }
class Dog extends Animal { bark(): string { return "dog"; } }

function late(x: string): Animal;
function late(x: "rex"): Dog;
function late(x: string | int32): Animal { return new Dog(); }

function early(x: "rex"): Dog;
function early(x: string): Animal;
function early(x: string | int32): Animal { return new Dog(); }

function union(x: string): Dog;
function union(x: "rex" | "fido"): Animal;
function union(x: string | int32): Animal { return new Dog(); }

type Rex = "rex";
function alias(x: string): Dog;
function alias(x: Rex): Animal;
function alias(x: string | int32): Animal { return new Dog(); }

function width(x: number): Animal;
function width(x: int32): Dog;
function width(x: number | string): Animal { return new Dog(); }

function fetch(this n: int32, x: string): Animal;
function fetch(this n: int32, x: "rex"): Dog;
function fetch(this n: int32, x: string | int32): Animal { return new Dog(); }

function fetchAll(this n: int32, x: string): Dog;
function fetchAll(this n: int32, x: "rex" | "fido"): Animal;
function fetchAll(this n: int32, x: string | int32): Animal { return new Dog(); }

const i: int32 = 3;
console.log(`first-signature ok ${late("rex").bark()} ${early("rex").bark()} ${union("rex").bark()} ${alias("rex").bark()} ${width(i).bark()} ${i.fetch("rex").bark()} ${i.fetchAll("rex").bark()}`);
