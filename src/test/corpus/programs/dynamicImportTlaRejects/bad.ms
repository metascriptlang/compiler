function failing(): boolean { return true; }

console.log("bad start");
await sleepAsync(1);
if (failing()) throw new Error("late boom");
console.log("bad unreachable");
export const value: int32 = 1;
