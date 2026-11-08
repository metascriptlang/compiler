import init, * as w from "/out/bench/wasmBoundary/wbweb/wbbench.js";
import { runRows } from "./rows.mjs";

await init();
runRows(w);
