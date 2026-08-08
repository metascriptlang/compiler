export interface Circle { kind: "circle"; r: float64; }
export interface Square { kind: "square"; side: float64; }

export type Shape = Circle | Square;
