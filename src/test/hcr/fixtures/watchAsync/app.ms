import { reload } from "std/hcr";
import { send, Conn, Channel } from "./logic";

const c = new Conn();
const sent = await send(c, "x");
const ch = new Channel();
const pushed = await ch.push("y");
console.log(`HCR-ASYNC ${sent.ok} ${pushed.ok}`);
reload();
