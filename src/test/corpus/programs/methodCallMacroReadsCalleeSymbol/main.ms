// @stdout: sent moveCard|columnCards 0
// @exit: 0
// note: a method-call macro reads the callee's declared name from the function it is handed and expands to an ordinary generic call, so the argument literal and the row type are checked by ordinary inference: `client.run(moveCard, {...})` and `client.live(columnCards, {...})`.

import { Client, Live, live, run } from "./sdk";
import { Card, columnCards, moveCard } from "./app";

const client = new Client();
const sent = client.run(moveCard, { id: 1, column: "done" });
const todo: Live<Card> = client.live(columnCards, { column: "todo" });
console.log(sent + "|" + todo.name + " " + todo.rows.length.toString());
