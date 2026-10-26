// @stdout: reclaimed interface true array true record true generic true extended true
// @skip-js: onDestroy does not run on JS
// A cycle that closes through a slot typed by an interface, an array of one, an unnamed record
// type, a generic over one, or an extended class is registered and freed: onDestroy runs for
// pairs of every family before exit, and the SAN lane sees each type's alloc equal its destroy.
// Sibling: cycleThroughAcyclicInterfaceStaysUnregistered (src/test/c/openSlotCycleClassification).
interface Shape {
	area: number;
}
class Square implements Shape {
	area: number = 4;
	owner: ShapeHolder | null = null;
	onDestroy(): void { destroyed[0] += 1; }
}
class ShapeHolder {
	shape: Shape | null = null;
}

class Circle implements Shape {
	area: number = 3;
	bag: ShapeBag | null = null;
	onDestroy(): void { destroyed[1] += 1; }
}
class ShapeBag {
	shapes: Shape[] = [];
}

type Area = { area: number };
class Tile {
	area: number = 1;
	owner: AreaHolder | null = null;
	onDestroy(): void { destroyed[2] += 1; }
}
class AreaHolder {
	slot: Area | null = null;
}

class Box<T> {
	value: T;
	constructor(value: T) { this.value = value; }
}
class Hexagon implements Shape {
	area: number = 6;
	boxed: BoxHolder | null = null;
	onDestroy(): void { destroyed[3] += 1; }
}
class BoxHolder {
	box: Box<Shape> | null = null;
}

class Base {
	tag: number = 0;
}
class Leaf extends Base {
	owner: BaseHolder | null = null;
	onDestroy(): void { destroyed[4] += 1; }
}
class BaseHolder {
	base: Base | null = null;
}

const destroyed: int32[] = [0, 0, 0, 0, 0];
const rounds: int32 = 1000;

function makeInterface(): void {
	const square = new Square();
	const holder = new ShapeHolder();
	holder.shape = square;
	square.owner = holder;
}
function makeArray(): void {
	const circle = new Circle();
	const bag = new ShapeBag();
	bag.shapes.push(circle);
	circle.bag = bag;
}
function makeRecord(): void {
	const tile = new Tile();
	const holder = new AreaHolder();
	holder.slot = tile;
	tile.owner = holder;
}
function makeGeneric(): void {
	const hexagon = new Hexagon();
	const holder = new BoxHolder();
	holder.box = new Box<Shape>(hexagon);
	hexagon.boxed = holder;
}
function makeExtended(): void {
	const leaf = new Leaf();
	const holder = new BaseHolder();
	holder.base = leaf;
	leaf.owner = holder;
}

for (let i: int32 = 0; i < rounds; i += 1) {
	makeInterface();
	makeArray();
	makeRecord();
	makeGeneric();
	makeExtended();
}
console.log(`reclaimed interface ${destroyed[0] > 0} array ${destroyed[1] > 0} record ${destroyed[2] > 0} generic ${destroyed[3] > 0} extended ${destroyed[4] > 0}`);
