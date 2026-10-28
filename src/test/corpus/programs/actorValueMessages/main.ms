// @stdout: messages 7 2 7 3 4
// @serial
// @xfail(raiser): actor constructors and mailbox calls are not in the Raiser VM yet (PARALOCK-raiser step 4)

import { Config, Service, StartedService } from "./service";

const service = new Service();
const config: Config = { x: 3, y: 4 };
service.configure(move config);
const value = await service.value();
const result = await service.result();
const point = await service.point();
const started = new StartedService(9);
const initialized = await started.snapshot();
if (!initialized.pidReady || initialized.value != 9) throw new Error("imported actor constructor ran before PID registration");
console.log(`messages ${value.x} ${value.y} ${result.ok ? result.value : -1} ${point.x} ${point.y}`);
