export class SendError {
	message: string;
	constructor(message: string) { this.message = message; }
}

export class Conn {
	count: int32 = 0;
}

async function frame(c: Conn, bytes: uint8[]): Promise<Result<void, SendError>> {
	c.count += bytes.length as int32;
	if (bytes.length == 0) return Result.err(new SendError("empty"));
	return Result.ok(null);
}

export async function send(this c: Conn, payload: string): Promise<Result<void, SendError>> {
	const bytes: uint8[] = [];
	for (let i = 0; i < payload.length; i += 1) bytes.push(payload.charCodeAt(i) as uint8);
	return await frame(c, bytes);
}

export class Channel {
	queued: string[] = [];

	async deliver(item: string): Promise<Result<void, SendError>> {
		if (item == "") return Result.err(new SendError("blank"));
		this.queued.push(item);
		return Result.ok(null);
	}

	async push(item: string): Promise<Result<void, SendError>> {
		return await this.deliver(item);
	}
}
