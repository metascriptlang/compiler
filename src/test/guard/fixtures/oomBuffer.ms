console.log("before the allocation");
const b = Buffer.alloc(2147483647);
console.log(`buffer length ${b.length}`);
