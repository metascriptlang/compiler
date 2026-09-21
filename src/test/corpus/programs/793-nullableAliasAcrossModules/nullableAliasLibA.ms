export type PositionType = "static" | "relative" | "absolute";

export interface StyleA { position: PositionType | null; }

export function makeA(): StyleA { return { position: null }; }
