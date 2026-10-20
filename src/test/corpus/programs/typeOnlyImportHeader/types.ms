import { slots } from "./gpu";
export struct Rgba { r: float32; g: float32; }
export function count(): int32 { return slots(); }
