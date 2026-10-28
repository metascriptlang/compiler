export struct V { x: int32; }
export struct W { x: int32; }

export function `&`(this a: V, b: V): V { return { x: a.x & b.x }; }
export function `|`(this a: V, b: V): V { return { x: a.x | b.x }; }
export function `^`(this a: V, b: V): V { return { x: a.x ^ b.x }; }
export function `<<`(this a: V, b: V): V { return { x: a.x << b.x }; }

export function `&`(this a: W, b: W): W { return { x: (a.x & b.x) + 100 }; }
export function `|`(this a: W, b: W): W { return { x: (a.x | b.x) + 100 }; }
export function `^`(this a: W, b: W): W { return { x: (a.x ^ b.x) + 100 }; }
export function `<<`(this a: W, b: W): W { return { x: (a.x << b.x) + 100 }; }
