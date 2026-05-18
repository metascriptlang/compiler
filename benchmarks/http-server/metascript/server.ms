import { createServer, sendJson, serveConcurrent } from "std/http/server";
import { HttpMethod, HttpRequest, ServerResponse } from "std/http/types";
import { cpuCount } from "std/os";

interface User {
	id: int32;
	name: string;
	email: string;
	created: int64;
}

function main(): void {
	const server = createServer((req: HttpRequest, res: ServerResponse): void => {
		if (req.method === HttpMethod.GET && req.path.startsWith("/users/")) {
			const idStr = req.path.slice(7, req.path.length);
			const id: int32 = idStr.parseInt() as int32;
			const user: User = {
				id: id,
				name: "User " + idStr,
				email: "user" + idStr + "@example.com",
				created: 1737000000,
			};
			sendJson(res, JSON.stringify<User>(user));
			return;
		}
		res.status = 404;
		res.end("");
	});

	const lr = server.listen("127.0.0.1", 8080);
	if (!lr.ok) {
		console.log("listen failed: " + lr.error.message);
		return;
	}
	server.keepAlive = true;
	serveConcurrent(server, cpuCount());
}

main();
