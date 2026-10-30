// @stdout: false true
// @stdout: true true
// @stdout: true false
interface Config { a?: number | null; b?: number | null; }
class Receiver {
	config: Config;
	constructor(config: Config | null = null) {
		if (config === null) { this.config = { a: null }; }
		else { this.config = config as Config; }
	}
	read(): void { console.log(this.config.a === null, this.config.b === null); }
}
new Receiver({ a: 0 }).read();
new Receiver().read();
new Receiver({ b: 1 }).read();
