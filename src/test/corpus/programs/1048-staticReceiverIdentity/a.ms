export class Gauge { v: int32 = 0; }
export function make(this typeof Gauge): int32 { return 11; }

export class Dial { static make(): int32 { return 31; } }

export type Tag = string;
export function make(this typeof Tag): string { return "tagA"; }
