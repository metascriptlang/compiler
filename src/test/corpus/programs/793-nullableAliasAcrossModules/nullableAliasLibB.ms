export type PositionType = "static" | "relative" | "absolute";

export interface StyleB { position: PositionType | null; }

export function makeB(): StyleB { return { position: "relative" }; }
