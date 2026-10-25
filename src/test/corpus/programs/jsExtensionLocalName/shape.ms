export interface Shape {
	readonly value: int32;
}
export function stride(this shape: Readonly<Shape>): int32 {
	return shape.value;
}
export function width(this shape: Readonly<Shape>): int32 {
	return shape.value + 1;
}
