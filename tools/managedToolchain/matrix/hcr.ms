import { reload } from "std/hcr";

for (let i = 0; i < 3; i = i + 1) { reload(); }
console.log("matrix-hcr", 6 * 7);
