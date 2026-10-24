import { Size, ShapeKind } from "../shape.h";
import { area, kindCode } from "../take";

export function farArea(): int32 { const s: Size = { w: 5, h: 2 }; return area(s); }
export function farKind(): int32 { return kindCode(ShapeKind.SHAPE_SQUARE); }
