export interface ExecFileResult {
	started: boolean;
	pipeOk: boolean;
	exitCode: int32;
	signal: int32;
	output: string;
	errorOutput: string;
	startErrno: int32;
}

export const CHILD_OK: int32 = 0;
export const CHILD_ENDED: int32 = 1;
export const CHILD_TIMEOUT: int32 = 2;
export const CHILD_PIPE_CLOSED: int32 = 3;
export const CHILD_OVERFLOW: int32 = 4;
export const CHILD_ERROR: int32 = 5;

export const SPAWN_MERGE_STDERR: int32 = 1;
export const SPAWN_OWN_GROUP: int32 = 2;

export const CHILD_BUFFER_CAP: int64 = 16 * 1024 * 1024;
