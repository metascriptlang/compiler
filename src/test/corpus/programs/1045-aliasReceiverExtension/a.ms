export type Meters = int32;
export type Label = string;

export function twice(this m: Meters): int32 { return m * 2; }

export function shout(this l: Label): Label { return l + "!"; }
