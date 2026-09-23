import { base, pair, tick, value } from "./logic";
import { Square, checked, makeSquare } from "./shapes";

@exportName("hcrIndirectValue")
export function hcrIndirectValue(): int32 {
	const read: () => int32 = base;
	return value() + pair(10).second + read();
}

@exportName("hcrShapeValue")
export function hcrShapeValue(): int32 {
	const shape = makeSquare(3);
	return shape instanceof Square ? shape.area() : -1;
}

@exportName("hcrTickValue")
export function hcrTickValue(): int32 {
	return tick();
}

@exportName("hcrErrorValue")
export function hcrErrorValue(): int32 {
	try {
		const value = checked(-1);
		return value;
	} catch (e) {
		return 1;
	}
}
