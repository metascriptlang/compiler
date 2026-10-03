// Parked at inbox card 2026-09-27-match-expression-contexts.md

function laterDeclaredShape(circle: boolean): LaterShape {
	if (circle) { const value: LaterCircle = { kind: "circle", label: "circle-payload", radius: 2.0 }; return value; }
	const value: LaterSquare = { kind: "square", label: "square-payload", width: 3.0 };
	return value;
}

interface LaterCircle { kind: "circle"; label: string; radius: float64; }

interface LaterSquare { kind: "square"; label: string; width: float64; }

type LaterShape = LaterCircle | LaterSquare;

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
