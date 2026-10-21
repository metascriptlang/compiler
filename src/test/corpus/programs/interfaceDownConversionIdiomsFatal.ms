// The checked replacement for a refused interface down-conversion: `as` to a class stops on
// a value of another class with the class conversion message on every backend.
// @exit: 1
// @stdout: before
// @stdout: Error: invalid object conversion: Sq is not Ci
// @xfail(danger): --danger drops the conversion check, so the wrong downcast reads the other class's memory instead of stopping
// @xfail(raiser): the Raiser stops at the same conversion with exit 1, but its 'raiser runtime error: invalid object conversion: …' goes to stderr, which the raiser cell keeps apart from the compared output

interface Shape { name: string; }
interface Circle extends Shape { radius: number; }
class Ci implements Circle { name: string = "ci"; radius: number = 3; }
class Sq implements Shape { name: string = "sq"; side: number = 2; }

function make(k: int32): Shape {
	if (k == 0) return new Ci();
	return new Sq();
}

console.log("before");
const c = make(1) as Ci;
console.log("after " + c.radius);
