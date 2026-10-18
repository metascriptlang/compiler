export struct R { id: int32 }
export function text(this r: R): string { return "t" + r.id.toString(); }
export enum Kind { A, B }
