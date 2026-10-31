// @mixed-error: never a nullable value
// @stdout: 3
// @stdout: -1
import { pick } from "./nullableRefusedWasm";

console.log(`${pick((x: int32): int32 | null => x + 2)}`);
console.log(`${pick((x: int32): int32 | null => null)}`);
