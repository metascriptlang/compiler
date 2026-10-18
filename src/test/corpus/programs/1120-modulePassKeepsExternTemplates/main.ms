// @xfail(raiser): raiser error: Cannot resolve module './lib' (an extern module, lib.cms on C and lib.jms on JS)
// @stdout: twice 3 mix 42
// note: a module pass receives every module and returns it; an `extern function … from "…"` comes back through the compile-time VM's node conversion, which must carry the `from` text, or the call is emitted as the bare MetaScript name. On JS the `from` is a template with one and with two `#`, on C the C symbol it binds. `bump` stays in its module and goes back as the pass got it; the exported `mix`, called from this module, is rebuilt by the pass from the `nativeName` it reads.

import { twice, mix } from "./lib";

console.log("twice " + twice(1).toString() + " mix " + mix(4, 2).toString());
