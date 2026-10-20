import { saw } from "./trace";
saw("shapes");
export struct Point { x: int32; y: int32; }
export function origin(): Point { return { x: 0, y: 0 }; }
