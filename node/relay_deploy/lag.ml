(* Reading relay versions and the lag lines (docs/releases.md, A relay left behind is named): record
   each relay's relay_version on every sync, judge a relay behind the newest relay release, and name
   it in its operator's digest after 2 days and in each release signer's after 7, once per release
   per relay.

   STUB: ISS-46052 ("digestif — reading relay versions and the lag lines", row 7 of DES-45470)
   fills this module. Until then no relay is judged behind. *)

(* Record what each relay reported at this sync. *)
let record (_ : Node.t) (_ : Sync.report) = ()

(* The lag lines this member's digest carries: their own relays 2 days behind, and, for a release
   signer, every relay 7 days behind. *)
let digest_lines (_ : Node.t) ~now:(_ : float) : Line.t list = []
