import { Shape, Size, ShapeKind } from "./shape.h";

export function handleState(s: Shape | null): int32 { return s === null ? 1 : 2; }
export function area(s: Size): int32 { return s.w * s.h; }
export function kindCode(k: ShapeKind): int32 { return k as int32; }
