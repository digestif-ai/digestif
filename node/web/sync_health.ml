(* What a sync's relay failures say, and the sync job's problem record it settles. A relay that
   could not be read while another relay, or the release channel, answered is the relay's problem:
   relay_unreachable. Every relay failing while the release channel cannot be reached either is
   this machine being offline, which is not a problem to fix and raises nothing. ISS-65273 *)

type verdict =
  | Reached_every_relay
  | Offline  (** no relay and not the release channel: the machine's network *)
  | Relay_unreachable  (** a relay failed while something else answered *)

(* [channel_reachable] is asked only when every relay failed, so a sync that reached a relay never
   spends a request on the release channel. A node with no relays reached every one of them. *)
let judge ~(relay_errors : string option list) ~channel_reachable =
  if List.for_all Option.is_none relay_errors then Reached_every_relay
  else if List.for_all Option.is_some relay_errors && not (channel_reachable ())
  then Offline
  else Relay_unreachable

(* A sync that reached every relay closes the problem. An offline machine leaves the record as it
   was: it says nothing about the relays either way. *)
let settle (log : Digestif_core.Log.t) verdict =
  let module P = Store.Problems in
  match verdict with
  | Reached_every_relay -> P.resolve log ~job:"sync" ()
  | Offline -> ()
  | Relay_unreachable ->
      ignore (P.report log ~job:"sync" ~kind:"relay_unreachable" ())
