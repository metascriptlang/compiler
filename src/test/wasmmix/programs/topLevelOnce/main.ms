// @stdout: helper ready
// @stdout: unread initialized
// @stdout: placed ready
// @stdout: 42
import { twice } from "./topLevelOnceWasm";

console.log(`${twice(21)}`);
