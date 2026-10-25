// @stdout: 42 | a 1 | 3 x | 7 | r
// note: positional `new` on a generic class without a constructor fills the instance's fields in declaration order, typed by the instantiated body rather than by the type arguments (`P<string>` takes a number first). Before, C stopped with "reached codegen unlowered" and JS dropped every argument.
class Box<T> { value: T; }
class KV<K, V> { key: K; val: V; }
class P<T> { n: number; v: T; }

function make(): Box<string> { return new Box<string>("r"); }

const b = new Box<number>(42);
const kv = new KV<string, number>("a", 1);
const p = new P<string>(3, "x");
const nested = new Box<Box<number>>(new Box<number>(7));
console.log(`${b.value} | ${kv.key} ${kv.val} | ${p.n} ${p.v} | ${nested.value.value} | ${make().value}`);
