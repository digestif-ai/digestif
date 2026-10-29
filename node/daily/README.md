# digestif_daily

The node's daily acts, run after every sync by `digestif run` (`Daily.run`): what turns the
constructions in `node/mail` into a member's digest, answer links and settled asks.

| Module | What it does |
|---|---|
| `Mail_key` | Appends the mail key's device body (signed at `digestif init`) once this machine's device key is admitted, and hands out the mail key's sequence numbers from a counter in the log |
| `Daily_digest` | Once a day after the digest hour: appends the queued asks, writes the digest (with an Updates section from `update-report.json` when an update pass has something to say), keeps its mail request, and sends it to the mailing relay once the relay holds the digest |
| `Decisions` | Acts on the first decision read for each of the member's asks before it lapses, or on its `on_no_answer` once it lapses |
| `Phones` | Admits a phone from its pairing code, with the enrollment that hands it the encryption key |
| `Store` | The tables beside the log: queued asks, unsent mail requests, settled outcomes |

The commands: `digestif ask add|list`, `digestif digest email|hour`, `digestif phone add`.
