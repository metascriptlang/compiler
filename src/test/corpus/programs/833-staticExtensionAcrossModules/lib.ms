export struct Pet { hunger: uint16; }
export struct Block { id: uint32; }
export enum Mood { Calm, Angry }

export function create(x: int32): int32 { return x + 1; }
export function create(this typeof Pet): Pet { return { hunger: 7 }; }
export function create(this typeof Block): Block { return { id: 9 }; }
export function fromByte(this typeof Mood, value: uint8): Mood { return (value as int32) as Mood; }

export function kindOf<T>(): uint8 { return T.accountKind(); }
