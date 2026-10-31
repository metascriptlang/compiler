const wall = Date.now();
const start = performance.now();
let sum = 0;
for (let i = 0; i < 20000000; i++) sum += i % 7;
const elapsed = performance.now() - start;
console.log(`${wall > 1700000000000} ${elapsed > 0} ${sum}`);
