// @stdout: helper a
// @stdout: helper base
// @stdout: helper b
// @stdout: kernel a
// @stdout: kernel k
// @stdout: static scale
// @stdout: pair
// @stdout: block local
// @stdout: kernel b
// @stdout: unread
// @stdout: 25 · scale 2 · hi 2 · same true
import { Cfg, calc, hiFromJs, stamp, stampInWasm } from "./initOnceWasm";

console.log(`${calc()} · scale ${Cfg.scale} · hi ${hiFromJs()} · same ${stamp == stampInWasm()}`);
