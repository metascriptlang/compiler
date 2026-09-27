interface VariantWideningCircle { kind: "circle"; r: float64; }

interface VariantWideningSquare { kind: "square"; s: float64; }

type VariantWideningShape = VariantWideningCircle | VariantWideningSquare;

function variantWideningTake(sh: VariantWideningShape): float64 {
	if (sh.kind == "circle") {
		return sh.r;
	}
	return sh.s;
}

function variantWideningPick(which: boolean): VariantWideningShape {
	if (which) {
		const c: VariantWideningCircle = { kind: "circle", r: 1.5 };
		return c;
	}
	const q: VariantWideningSquare = { kind: "square", s: 2.5 };
	return q;
}

function variantWideningRes(which: boolean): Result<VariantWideningShape, string> {
	if (which) {
		const c: VariantWideningCircle = { kind: "circle", r: 4.5 };
		return Result.ok(c);
	}
	return Result.err("nope");
}

interface ProjectCircle { kind: "circle"; radius: float64; }

interface ProjectSquare { kind: "square"; width: float64; }

type ProjectShape = ProjectCircle | ProjectSquare;

function shapeArea(shape: ProjectShape): float64 {
	return match (shape.kind) {
		"circle" => shape.radius * shape.radius,
		"square" => shape.width * shape.width,
	};
}

function shapeSize(shape: ProjectShape): float64 {
	if (shape.kind == "circle") return shape.radius;
	return shape.width;
}

function pickShape(circle: boolean): ProjectShape {
	if (circle) { const shape: ProjectCircle = { kind: "circle", radius: 3.0 }; return shape; }
	const shape: ProjectSquare = { kind: "square", width: 4.0 };
	return shape;
}

function laterDeclaredShape(circle: boolean): LaterShape {
	if (circle) { const value: LaterCircle = { kind: "circle", label: "circle-payload", radius: 2.0 }; return value; }
	const value: LaterSquare = { kind: "square", label: "square-payload", width: 3.0 };
	return value;
}

interface LaterCircle { kind: "circle"; label: string; radius: float64; }

interface LaterSquare { kind: "square"; label: string; width: float64; }

type LaterShape = LaterCircle | LaterSquare;

test "unionPayloads: variant widens at var init" {
	const c: VariantWideningCircle = { kind: "circle", r: 3.0 };
	const a: VariantWideningShape = c;
	assert a.kind == "circle";
	assert variantWideningTake(a) == 3.0;
}

test "unionPayloads: variant widens at reassignment" {
	const c: VariantWideningCircle = { kind: "circle", r: 5.0 };
	let b: VariantWideningShape = { kind: "square", s: 2.0 };
	assert b.kind == "square";
	b = c;
	assert b.kind == "circle";
	assert variantWideningTake(b) == 5.0;
}

test "unionPayloads: variant widens at a plain call argument" {
	const c: VariantWideningCircle = { kind: "circle", r: 6.0 };
	assert variantWideningTake(c) == 6.0;
}

test "unionPayloads: variant widens on return" {
	const s = variantWideningPick(true);
	assert s.kind == "circle";
	const q = variantWideningPick(false);
	assert q.kind == "square";
}

test "unionPayloads: variant widens through Result.ok generic inference" {
	const r = variantWideningRes(true);
	assert r.ok;
	if (r.ok) {
		assert r.value.kind == "circle";
	}
}

test "unionPayloads: source stays readable after a copying widen" {
	const c: VariantWideningCircle = { kind: "circle", r: 9.0 };
	const s: VariantWideningShape = c;
	assert c.r == 9.0;
	assert variantWideningTake(s) == 9.0;
}

test "unionPayloads: narrowed union payloads remain readable and re-widen at every consumer" {
	for (const circle of [true, false]) {
		const shape = pickShape(circle);
		assert (shape.kind == "circle") == circle;
		if (shape.kind == "circle") {
			assert shape.radius == 3.0;
			assert shape.radius + shape.radius == 6.0;
			assert shapeSize(shape) == shape.radius;
			assert shapeArea(shape) + shapeArea(shape) == 18.0;
			const wide: ProjectShape = shape;
			assert shapeArea(wide) == 9.0;
		} else {
			assert shape.width == 4.0;
			assert shape.width + shape.width == 8.0;
			assert shapeSize(shape) == shape.width;
			assert shapeArea(shape) + shapeArea(shape) == 32.0;
			const wide: ProjectShape = shape;
			assert shapeArea(wide) == 16.0;
		}
	}
}

test "unionPayloads: lifted consumers use later-declared variant payloads in both arms" {
	const area = (shape: LaterShape): float64 => match (shape.kind) {
		"circle" => shape.radius * shape.radius,
		"square" => shape.width * shape.width,
	};
	for (const circle of [true, false]) {
		const value = laterDeclaredShape(circle);
		assert area(value) == (circle ? 4.0 : 9.0);
		assert value.label == (circle ? "circle-payload" : "square-payload");
	}
}
