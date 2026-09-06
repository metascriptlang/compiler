// Language tests: OOP patterns — interface-based classes, composition, state machines
// NOTE: class with `this` not yet in C backend, using interface+function pattern

enum ShapeKind { Circle, Square, Triangle }
enum State { Idle, Running, Paused, Done }

interface Animal { name: string; legs: number; }
interface Counter { value: number; }
interface Rectangle { width: number; height: number; }
interface Person { first: string; last: string; age: number; }
interface CircleShape { kind: string; radius: number; }
interface ShapeData { kind: ShapeKind; size: number; }
interface Machine { state: State; progress: number; }

function animalDescribe(a: Animal): string { return a.name + " has " + a.legs + " legs"; }
function counterInc(c: Counter): void { c.value += 1; }
function counterAdd(c: Counter, n: number): void { c.value += n; }
function rectArea(r: Rectangle): number { return r.width * r.height; }
function rectPerimeter(r: Rectangle): number { return 2 * (r.width + r.height); }
function rectIsSquare(r: Rectangle): boolean { return r.width == r.height; }
function personFullName(p: Person): string { return p.first + " " + p.last; }
function circleArea(c: CircleShape): number { return 3.14159 * c.radius * c.radius; }

function shapeArea(s: ShapeData): number {
	return match (s.kind) {
		ShapeKind.Circle => 3.14159 * s.size * s.size,
		ShapeKind.Square => s.size * s.size,
		ShapeKind.Triangle => s.size * s.size / 2,
	};
}

function shapeName(s: ShapeData): string {
	return match (s.kind) {
		ShapeKind.Circle => "circle",
		ShapeKind.Square => "square",
		ShapeKind.Triangle => "triangle",
	};
}

function machineStart(m: Machine): void { if (m.state == State.Idle) m.state = State.Running; }
function machineStep(m: Machine): void {
	if (m.state == State.Running) {
		m.progress += 10;
		if (m.progress >= 100) m.state = State.Done;
	}
}
function machinePause(m: Machine): void { if (m.state == State.Running) m.state = State.Paused; }
function machineResume(m: Machine): void { if (m.state == State.Paused) m.state = State.Running; }

test "basic OOP via interface" {
	const cat: Animal = { name: "cat", legs: 4 };
	assert cat.name == "cat";
	assert cat.legs == 4;
	assert animalDescribe(cat) == "cat has 4 legs";
}

test "multiple instances" {
	const dog: Animal = { name: "dog", legs: 4 };
	const spider: Animal = { name: "spider", legs: 8 };
	assert dog.name == "dog";
	assert spider.legs == 8;
	assert animalDescribe(dog) != animalDescribe(spider);
}

test "mutable state (counter)" {
	const ctr: Counter = { value: 0 };
	assert ctr.value == 0;
	counterInc(ctr);
	counterInc(ctr);
	counterInc(ctr);
	assert ctr.value == 3;
	counterAdd(ctr, 7);
	assert ctr.value == 10;
}

test "computed methods (rectangle)" {
	const rect: Rectangle = { width: 10, height: 5 };
	assert rectArea(rect) == 50;
	assert rectPerimeter(rect) == 30;
	assert !rectIsSquare(rect);

	const sq: Rectangle = { width: 7, height: 7 };
	assert rectIsSquare(sq);
	assert rectArea(sq) == 49;
}

test "string fields (person)" {
	const p: Person = { first: "John", last: "Doe", age: 30 };
	assert personFullName(p) == "John Doe";
	assert p.age == 30;
}

test "composition (circle)" {
	const c: CircleShape = { kind: "circle", radius: 5 };
	assert c.kind == "circle";
	assert c.radius == 5;
	assert circleArea(c) > 78;
	assert circleArea(c) < 79;
}

test "enum dispatch (polymorphism)" {
	const sqr: ShapeData = { kind: ShapeKind.Square, size: 4 };
	const tri: ShapeData = { kind: ShapeKind.Triangle, size: 6 };
	assert shapeName(sqr) == "square";
	assert shapeName(tri) == "triangle";
	assert shapeArea(sqr) == 16;
	assert shapeArea(tri) == 18;
}

test "state machine" {
	const m: Machine = { state: State.Idle, progress: 0 };
	assert m.state == State.Idle;

	machineStart(m);
	assert m.state == State.Running;

	machineStep(m);
	machineStep(m);
	assert m.progress == 20;

	machinePause(m);
	assert m.state == State.Paused;
	machineStep(m);
	assert m.progress == 20;

	machineResume(m);
	assert m.state == State.Running;

	let steps = 0;
	while (m.state == State.Running) {
		machineStep(m);
		steps += 1;
	}
	assert m.state == State.Done;
	assert m.progress == 100;
}
