// A tagged struct held in a field of another tagged struct reads back through JSON.parse<T>
// by the path a top-level tagged struct takes: required, nullable, in an array and two
// levels deep, and a wrong nested kind is refused naming its field.
//
// @stdout: round {"kind":"Run","command":{"kind":"Set","value":7}}
// @stdout: round {"kind":"Status"}
// @stdout: round {"kind":"Maybe","command":{"kind":"Clear"}}
// @stdout: round {"kind":"Maybe","command":null}
// @stdout: round {"kind":"Batch","commands":[{"kind":"Set","value":1},{"kind":"Clear"}]}
// @stdout: round {"kind":"Send","request":{"kind":"Run","command":{"kind":"Set","value":9}}}
// @stdout: round {"kind":"Ping"}
// @stdout: round {"kind":"Tune","mode":"~alt"}
// @stdout: round {"kind":"Tune"}
// @stdout: field 'command.kind': unknown discriminator value 'Nope'; field 'command.value': expected int, got null
// @stdout: field 'command': expected object, got null; field 'command.kind': expected string, got null; field 'command.kind': unknown discriminator value ''; field 'command.value': expected int, got null
// @stdout: field 'command': expected object, got null; field 'command.kind': expected string, got null; field 'command.kind': unknown discriminator value ''; field 'command.value': expected int, got null
// @stdout: field 'command.kind': unknown discriminator value 'Nope'; field 'command.value': expected int, got null
// @stdout: field 'commands[0].kind': unknown discriminator value 'Nope'; field 'commands[0].value': expected int, got null
// @stdout: field 'request.command.kind': unknown discriminator value 'Nope'; field 'request.command.value': expected int, got null
// @exit: 0

type Mode = "alt" | "~alt";

enum CommandKind {
	Set,
	Clear,
}

struct Command = match (kind: CommandKind) {
	CommandKind.Set => { value: int32 },
	CommandKind.Clear => {},
};

enum RequestKind {
	Run,
	Status,
	Maybe,
	Batch,
	Tune,
}

struct Request = match (kind: RequestKind) {
	RequestKind.Run => { command: Command },
	RequestKind.Status => {},
	RequestKind.Maybe => { command: Command | null },
	RequestKind.Batch => { commands: Command[] },
	RequestKind.Tune => { mode?: Mode },
};

enum EnvelopeKind {
	Send,
	Ping,
}

struct Envelope = match (kind: EnvelopeKind) {
	EnvelopeKind.Send => { request: Request },
	EnvelopeKind.Ping => {},
};

function roundTrip<T>(text: string, witness: T | null): void {
	const back = JSON.parse<T>(text);
	console.log(back.ok && JSON.stringify(back.value) == text ? "round " + text : "broken " + (back.ok ? JSON.stringify(back.value) : back.error));
}

roundTrip<Request>('{"kind":"Run","command":{"kind":"Set","value":7}}', null);
roundTrip<Request>('{"kind":"Status"}', null);
roundTrip<Request>('{"kind":"Maybe","command":{"kind":"Clear"}}', null);
roundTrip<Request>('{"kind":"Maybe","command":null}', null);
roundTrip<Request>('{"kind":"Batch","commands":[{"kind":"Set","value":1},{"kind":"Clear"}]}', null);
roundTrip<Envelope>('{"kind":"Send","request":{"kind":"Run","command":{"kind":"Set","value":9}}}', null);
roundTrip<Envelope>('{"kind":"Ping"}', null);
roundTrip<Request>('{"kind":"Tune","mode":"~alt"}', null);
roundTrip<Request>('{"kind":"Tune"}', null);
function refuse<T>(text: string, witness: T | null): void {
	const r = JSON.parse<T>(text);
	console.log(r.ok ? "accepted" : r.error);
}

refuse<Request>('{"kind":"Run","command":{"kind":"Nope"}}', null);
refuse<Request>('{"kind":"Run"}', null);
refuse<Request>('{"kind":"Run","command":null}', null);
refuse<Request>('{"kind":"Maybe","command":{"kind":"Nope"}}', null);
refuse<Request>('{"kind":"Batch","commands":[{"kind":"Nope"}]}', null);
refuse<Envelope>('{"kind":"Send","request":{"kind":"Run","command":{"kind":"Nope"}}}', null);
