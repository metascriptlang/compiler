// @stdout: tla-export got 5
async function g(): Promise<int32> { return 5; }
export const v = await g();
console.log("tla-export got " + v);
