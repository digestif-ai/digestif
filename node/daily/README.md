# digestif_daily

The node's daily acts, run after every sync by `digestif run` (`Daily.run`): what turns the
constructions in `node/mail` into a member's digest, answer links and settled asks.

| Module | What it does |
|---|---|
| `Mail_key` | Appends the mail key's device body (signed at `digestif init`) once this machine's device key is admitted, and hands out the mail key's sequence numbers from a counter in the log |
| `Daily_digest` | Once a day after the digest hour and outside the member's quiet hours (`Digestif_core.Quiet_hours`): appends every open ask in the node's ask store (`Digestif_core.Asks`) no digest has carried, records each one's envelope hash on the ask, writes the digest (with an Updates section from `update-report.json` when an update pass has something to say), keeps its mail request, and sends it to the mailing relay once the relay holds the digest |
| `Decisions` | Acts on the first decision read for each open ask's envelope before it lapses, or on its `on_no_answer` once it lapses, and records the answer in `Asks`; a `join:` ask's answer goes to `Invite_node.answer`, which writes the revoke with the device key that wrote the dinner while the fold allows it, and its lapse to `Invite_node.lapsed` (`Host_watch.lapsed`), which does the same inside the window and otherwise leaves the ask open; `needs_phrase` lists those, and the digest leads with them |
| `Asks_mail` | Converts between an ask in `Asks` and the sealed ask body a digest appends |
| `Phones` | Admits a phone from its pairing code, with the enrollment that hands it the encryption key |
| `Store` | The table beside the log: unsent mail requests |

The commands: `digestif ask add|list`, `digestif digest email|hour`, `digestif phone add`.
