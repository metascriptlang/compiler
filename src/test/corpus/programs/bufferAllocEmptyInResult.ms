// @stdout: empty=0 kind=needMore

import { Buffer } from "std/core/buffer";

type Frame = { kind: "needMore"; body: Buffer } | { kind: "ready"; body: Buffer };

function needMore(): Frame {
	return { kind: "needMore", body: Buffer.alloc(0) };
}

const frame = needMore();
console.log(`empty=${frame.body.length} kind=${frame.kind}`);
