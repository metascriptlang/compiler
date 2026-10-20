// @stdout: inits=[shapes,brush,tones] area=12 origin=0,0 painter=none
// note: TypeScript's `type` spellings on imports and re-exports compile as their plain form, so TS pasted in keeps building. A binding used only as a type does not run its module (`size`, `geo`). The barrel runs because `origin` is a value, and so do the modules its re-exports name with a value: `shapes`, the class `brush`, and `tones` behind `export type *`, which is a plain `export *`. `paint` re-exports only an interface and stays unevaluated.

import { inits } from "./lib/trace";
import type { Size } from "./lib/size";
import type * as geo from "./lib/geo";
import { type Painter, type Point, origin } from "./lib/barrel";
import type { Tone } from "./lib/barrel";
import { type Brush } from "./lib/barrel";

const size: Size = { w: 3, h: 4 };
const at: Point = origin();
const box: geo.Rect = { size: size };
const painter: Painter | null = null;
const tone: Tone | null = null;
const brush: Brush | null = null;
console.log(`inits=[${inits.join(",")}] area=${box.size.w * box.size.h} origin=${at.x},${at.y} painter=${painter == null && tone == null && brush == null ? "none" : "some"}`);
