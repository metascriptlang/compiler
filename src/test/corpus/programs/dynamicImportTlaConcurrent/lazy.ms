console.log("lazy start");
export let loads: int32 = 0;
loads += 1;
await sleepAsync(3);
console.log("lazy end");
