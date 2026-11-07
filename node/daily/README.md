# digestif_daily

The node's daily acts, run after every sync by `digestif run` (`Daily.run`): what turns the
constructions in `node/mail` into a member's digest, answer links and the node's settled choices.

| Module | What it does |
|---|---|
| `Mail_key` | Appends the mail key's device body (signed at `digestif init`) once this machine's device key is admitted, and hands out the mail key's sequence numbers from a counter in the log |
| `Daily_digest` | On every pass, appends every open ask in the node's ask store (`Digestif_core.Asks`) not on the wire yet as the node's choice, an item addressed to the member alone, and records its hash on the ask. Once a day after the digest hour and outside the member's quiet hours (`Digestif_core.Quiet_hours`): writes the digest, its Inbox part (every Draft and New item, from the web store's `Digest_lines.machine`, else the node's open choices) with page links, pick links and Acknowledge links, its sections, an Updates section from `update-report.json` when an update pass has something to say, and Your agent did; keeps its mail request, and sends it to the mailing relay once the relay holds the digest |
| `Decisions` | Acts on the first decision (a pick on the ask's choice) read for each open ask's envelope before it lapses, or on its `on_no_answer` once it lapses, and records the answer in `Asks`; a `join:` ask's answer goes to `Invite_node.answer`, which writes the revoke with the device key that wrote the dinner while the fold allows it, and its lapse to `Invite_node.lapsed` (`Host_watch.lapsed`), which does the same inside the window and otherwise leaves the ask open; `needs_phrase` lists those, and the digest leads with them |
| `Asks_mail` | Raises an ask in `Asks` and writes the node's choice item that carries it on the wire |
| `Phones` | Admits a phone from its pairing code, with the enrollment that hands it the encryption key |
| `Store` | The table beside the log: unsent mail requests |

The commands: `digestif digest email|hour`, `digestif phone add`.
