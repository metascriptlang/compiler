export type FlexDirection = "row" | "column" | "row-reverse" | "column-reverse";

export interface StyleB { dir: FlexDirection | null; }

export function makeB(): StyleB { return { dir: "row-reverse" }; }
