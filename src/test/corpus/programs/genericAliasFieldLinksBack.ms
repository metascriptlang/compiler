// @stdout: h3 2 1
// note: a class field typed through a generic alias of the class itself, substituted from a generic function return.
class Node<T> { kids: Alias<T>[] = []; v: T; constructor(v: T) { this.v = v; } add(k: Alias<T>): void { this.kids.push(k); } }
type Alias<T> = Node<T>;
type Forest<T> = Alias<Alias<T>[]>;
function mk<U>(v: U): Alias<U> { return new Node(v); }
const n = mk(1); n.add(mk(2));
const f: Forest<int32> = new Node<Alias<int32>[]>([n]);
console.log("h3 " + String(n.kids[0].v) + " " + String(f.v[0].v));
