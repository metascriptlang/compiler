import { Tracker, note } from "./tracker";
note("slow start");
export const early = new Tracker("slow early");
await sleepAsync(50);
export const held = new Tracker("slow");
note("slow end");
