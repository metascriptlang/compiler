// @stdout: 1 0 2 0|0 3

@passC("-Werror=incompatible-pointer-types");

enum ShapeKind { Zed, Alpha, Mid }
enum PlaceKind { Right, Left }

struct Shape = match (kind: ShapeKind) {
	ShapeKind.Zed => { z: int32 },
	ShapeKind.Alpha => { a: int32, b: int32 },
	ShapeKind.Mid => { m: int32 },
};

struct Place = match (kind: PlaceKind) {
	PlaceKind.Right => { r: int32 },
	PlaceKind.Left => { l: int32, extra: int32 },
};

struct Holder {
	shape: Shape | null;
	place: Place | null;
	list: (Shape | null)[];
}

function weight(this s: Shape): int32 {
	return s.kind == ShapeKind.Zed ? 1 : s.kind == ShapeKind.Alpha ? 2 : 3;
}

function weightOfPlace(this p: Place): int32 {
	return p.kind == PlaceKind.Right ? 1 : 0;
}

function shapeSeen(this h: Holder): int32 {
	let seen = 0;
	if (h.shape !== null) { seen = 1; }
	const shape: Shape | null = h.shape;
	return shape !== null ? shape.weight() : seen;
}

function placeSeen(this h: Holder): int32 {
	let seen = 0;
	if (h.place !== null) { seen = 1; }
	const place: Place | null = h.place;
	return place !== null ? place.weightOfPlace() : seen;
}

function elementSeen(this h: Holder): int32 {
	let seen = 0;
	if (h.list[0] !== null) { seen = 1; }
	const first: Shape | null = h.list[0];
	return first !== null ? first.weight() : seen;
}

function main(): void {
	const zed: Shape = { kind: ShapeKind.Zed, z: 5 };
	const mid: Shape = { kind: ShapeKind.Mid, m: 6 };
	const right: Place = { kind: PlaceKind.Right, r: 7 };
	const a: Holder = { shape: zed, place: null, list: [mid] };
	const b: Holder = { shape: null, place: right, list: [null] };
	console.log(`${a.shapeSeen()} ${b.shapeSeen()} ${b.placeSeen() + 1} ${a.placeSeen()}|${b.elementSeen()} ${a.elementSeen()}`);
}
main();
