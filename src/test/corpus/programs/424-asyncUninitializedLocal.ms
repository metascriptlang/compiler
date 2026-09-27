struct Point { x: int32; y: int32; }

class Tag {
	name: string;
	constructor(name: string) { this.name = name; }
}

async function val(v: int32): Promise<int32> { return v; }

async function pickInt(c: boolean): Promise<int32> {
	let x: int32;
	if (c) {
		const v = await val(1);
		x = v;
	} else {
		x = 7;
	}
	return x;
}

async function pickString(c: boolean): Promise<string> {
	let s: string;
	if (c) {
		const v = await val(1);
		s = `n${v}`;
	} else {
		s = "seven";
	}
	return s;
}

async function pickPoint(c: boolean): Promise<Point> {
	let p: Point;
	if (c) {
		const v = await val(1);
		p = { x: v, y: v };
	} else {
		p = { x: 7, y: 8 };
	}
	return p;
}

async function pickTag(c: boolean): Promise<Tag> {
	let t: Tag;
	if (c) {
		const v = await val(1);
		t = new Tag(`n${v}`);
	} else {
		t = new Tag("seven");
	}
	return t;
}

const p0 = await pickPoint(false);
const p1 = await pickPoint(true);
console.log(`int ${await pickInt(false)} ${await pickInt(true)}`);
console.log(`string ${await pickString(false)} ${await pickString(true)}`);
console.log(`struct ${p0.x},${p0.y} ${p1.x},${p1.y}`);
const t0 = await pickTag(false);
const t1 = await pickTag(true);
console.log(`class ${t0.name} ${t1.name}`);
