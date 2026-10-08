export struct Vec4 { x: float32; y: float32; z: float32; w: float32; }
export struct Mat4 { s: float32; }
export struct Tile { view: uint32; w: float32; }
export struct Cell { x: float32; tile: Tile; }
export struct Grid { index: int32; }
export function `*`(this v: Vec4, m: Mat4): Vec4 { return { x: v.x * m.s, y: v.y * m.s, z: v.z * m.s, w: v.w }; }
export function `*`(this v: Vec4, k: float32): Vec4 { return { x: v.x * k, y: v.y * k, z: v.z * k, w: v.w * k }; }
export function `+`(this m: Mat4, v: Vec4): float32 { return m.s + v.w; }
export function put(this g: Grid, t: Tile): float32 { return t.w; }
export function put(this g: Grid, k: int32, c: Cell): float32 { return c.tile.w + (k as float32); }
