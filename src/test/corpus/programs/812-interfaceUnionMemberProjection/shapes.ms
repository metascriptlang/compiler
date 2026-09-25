export interface Tri { kind: "tri"; base: number; height: number }
export interface Rect { kind: "rect"; w: number; h: number }
export type Poly = Tri | Rect;
