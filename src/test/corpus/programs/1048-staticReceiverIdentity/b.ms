export class Gauge { v: int32 = 0; }
export function make(this typeof Gauge): int32 { return 22; }

export class Dial { static make(): int32 { return 32; }  }

export type Tag = string;
export function make(this typeof Tag): string { return "tagB"; }
