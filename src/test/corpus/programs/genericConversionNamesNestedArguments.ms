// @exit: 1
// @stdout: Pair<int32, Box<string>> is not Target
// @xfail(danger): unchecked class conversions do not stop

class Box<T> { value: T; constructor(value: T) { this.value = value; } }
class Pair<A, B> { first: A; second: B; constructor(first: A, second: B) { this.first = first; this.second = second; } }
class Target { marker: int32 = 1; }

function made(): unknown { return new Pair<int32, Box<string>>(3, new Box<string>("s")); }

console.log(`before ${new Pair<int32, Box<string>>(1, new Box<string>("t")).first}`);
const wrong = made() as Target;
console.log(`after ${wrong.marker}`);
