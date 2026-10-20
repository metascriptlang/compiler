import { saw } from "./trace";
saw("mixed");
export struct Pt { x: int32; y: int32; }
export function mk(x: int32, y: int32): Pt { return { x: x, y: y }; }
