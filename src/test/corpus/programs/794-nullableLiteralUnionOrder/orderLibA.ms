export type FlexDirection = "column" | "column-reverse" | "row" | "row-reverse";

export interface StyleA { dir: FlexDirection | null; }

export function makeA(): StyleA { return { dir: null }; }
