export enum Color { Red, Green, Blue }
export enum Status { Active = 5, Inactive = 2 }
export interface Pixel { c: Color; x: int32; }
export interface Frame { p: Pixel; cs: Color[]; s: Status; }
