import { changedTime, modifiedTime, writeFile, ensureDir, removeAll } from "std/fs";

const SCRATCH = "out/changedTimeTest";

test "changedTime is -1 for a missing path" {
	assert changedTime(`${SCRATCH}/missing`) == -1;
}

test "changedTime of a file just written is the current second" {
	assert ensureDir(SCRATCH).ok;
	assert writeFile(`${SCRATCH}/file`, "x").ok;
	const changed = changedTime(`${SCRATCH}/file`);
	assert changed > 0;
	assert changed >= modifiedTime(`${SCRATCH}/file`);
	assert Math.abs(changed - Date.now() / 1000) < 5;
	assert removeAll(SCRATCH).ok;
}
