// @stdout: h3 2 1
// note: a generic class that names itself back through an alias (`Node<T>` holds `Alias<T>[]`, `Alias<T> = Node<T>`), instantiated through a generic function and again with an array of itself as the argument. Substituting the class body meets the class again, which the checker must leave to be filled later rather than reuse an instance still under construction: reusing it refused `mk(1)` with "cannot instantiate: 'U'". Same output on every backend.
class Node<T> { kids: Alias<T>[] = []; v: T; constructor(v: T) { this.v = v; } add(k: Alias<T>): void { this.kids.push(k); } }
type Alias<T> = Node<T>;
type Forest<T> = Alias<Alias<T>[]>;
function mk<U>(v: U): Alias<U> { return new Node(v); }
const n = mk(1); n.add(mk(2));
const f: Forest<int32> = new Node<Alias<int32>[]>([n]);
console.log("h3 " + String(n.kids[0].v) + " " + String(f.v[0].v));
