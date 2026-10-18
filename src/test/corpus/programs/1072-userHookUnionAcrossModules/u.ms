export struct A { n: int32; }
export struct B { s: string; }
export type U = A | B;

let destroyed: int32 = 0;

export function onDestroy(this u: U): void { destroyed += 1; }
export function destroyedCount(): int32 { return destroyed; }
