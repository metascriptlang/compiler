// An overloaded function used as a value binds the overload matching the function type of its
// slot, as a direct call does: a typed variable, an argument, a generic callback, a return slot,
// overloads by parameter type and by arity. The refusals live in handoff/overloadValue.ms.
// @stdout: direct Dog
// @stdout: value Dog
// @stdout: arg Dog
// @stdout: map Dog
// @stdout: return str
// @stdout: arity k2 k1
// @stdout: param int

class Animal { name(): string { return "a"; } }
class Dog extends Animal { bark(): string { return "w"; } }

function f(a: Animal): string { return "Animal"; }
function f(d: Dog): string { return "Dog"; }

function k(a: int32): string { return "k1"; }
function k(a: int32, b: int32): string { return "k2"; }

function h(x: int32): string { return "int"; }
function h(x: string): string { return "str"; }

function apply(fn: (d: Dog) => string, d: Dog): string { return fn(d); }
function pick(): (x: string) => string { return h; }

const ds: Dog[] = [new Dog()];
console.log("direct", f(ds[0]));
const g: (d: Dog) => string = f;
console.log("value", g(new Dog()));
console.log("arg", apply(f, new Dog()));
console.log("map", ds.map(f)[0]);
console.log("return", pick()("q"));
const k2: (a: int32, b: int32) => string = k;
const k1: (a: int32) => string = k;
console.log("arity", k2(1, 2), k1(1));
const hi: (x: int32) => string = h;
console.log("param", hi(1));
