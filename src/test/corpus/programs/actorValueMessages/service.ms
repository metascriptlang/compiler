export struct Config { x: int32; y: int32; }
export struct Value { x: int32; y: int32; }
export interface Point { x: number; y: number; }
export struct InitSnapshot { value: int32; pidReady: boolean; }

export actor Service {
	total: int32 = 0;
	configure(config: Config): void { this.total = config.x + config.y; }
	value(): Value { return { x: this.total, y: 2 }; }
	result(): Result<number, string> { return Result.ok(this.total); }
	point(): Point { return { x: 3, y: 4 }; }
}

export actor StartedService {
	value: int32 = 0;
	pidReady: boolean = false;
	constructor(value: int32) {
		this.pidReady = this.pid != 0;
		this.value = value;
	}
	snapshot(): InitSnapshot { return { value: this.value, pidReady: this.pidReady }; }
}
