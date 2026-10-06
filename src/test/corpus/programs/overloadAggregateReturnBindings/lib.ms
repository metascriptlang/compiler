export struct Pair { a: int32; b: int32; }

export function mk(x: int32): Pair { return { a: x, b: 1 }; }
export function mk(x: int32, y: int32): Pair { return { a: x, b: y }; }
export function mk(x: int32, y: int32, z: int32): Pair { return { a: x + z, b: y + z }; }
