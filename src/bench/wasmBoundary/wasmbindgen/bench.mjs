import { createRequire } from "node:module";
import { runRows } from "./rows.mjs";

runRows(createRequire(import.meta.url)(process.env.WB_MODULE));
