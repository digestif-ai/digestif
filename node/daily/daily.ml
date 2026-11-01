(* One pass of the daily acts, run after every sync: apply the release-key revocations the circle
   carries to the update state, so a node whose release channel withholds one still halts its
   updates, read the recalls it carries for the next update pass (Circle_recall), admit this machine's mail key once its device key is admitted, settle the asks decisions or lapses answer (writing a join ask's revoke), write
   the digest when it is due, and send the mail requests whose digest the mailing relay holds. *)

open Digestif_core

type report = {
  release_revocations : (Keys.public_key list, string) result;
      (** release keys a circle revocation newly revoked; an update state the
          node could not read is reported and blocks nothing else *)
  release_recalls :
    Digestif_update.Release.recall Digestif_update.Release.signed list;
      (** every recall the circle carries, which the update pass counts with the
          channel's against its own signer set *)
  mail_key : Mail_key.admission;
  settled : Decisions.ask list;
  needs_phrase : Asks.t list;
      (** lapsed join asks past the device key's window, which the digest leads
          with *)
  digest : (Daily_digest.written option, string) result;
  sent : Daily_digest.sent list;
  wrote : bool;
      (** something new went into the log, so another sync should push it *)
}

let ( let* ) = Result.bind

let pass ?transport ?silence ?(now = Unix.gettimeofday ()) (node : Node.t) =
  let fold = Node.fold node in
  let release_revocations =
    Digestif_update.Circle_revocation.from_circle
      ~state_path:(Digestif_update.Schedule.state_path node.dir)
      node fold
  in
  let release_recalls = Digestif_update.Circle_recall.from_circle node fold in
  let* mail_key = Mail_key.admit node fold in
  let fold = match mail_key with Appended _ -> Node.fold node | _ -> fold in
  let* settled = Decisions.settle node fold ~now in
  let needs_phrase = Decisions.needs_phrase node ~now in
  let digest =
    if Daily_digest.due node ~now then
      Result.map Option.some (Daily_digest.write ?silence node ~now)
    else Ok None
  in
  let* sent = Daily_digest.send ?transport node in
  let wrote =
    (match mail_key with Appended _ -> true | _ -> false)
    || List.exists (fun (a : Decisions.ask) -> a.revoke <> None) settled
    || match digest with Ok (Some _) -> true | _ -> false
  in
  Ok
    {
      release_revocations;
      release_recalls;
      mail_key;
      settled;
      needs_phrase;
      digest;
      sent;
      wrote;
    }

(* Sync, run the pass, and when the pass wrote something sync again so it reaches every relay, then
   send the mail requests that sync made sendable. [sync] replaces the plain sync, so the binary can
   run the invite join watcher over what each sync stores. *)
let run ?(transport = Relay_client.curl) ?silence ?now ?sync (node : Node.t) =
  let sync =
    match sync with Some f -> f | None -> fun n -> Sync.sync ~transport n
  in
  let* first = sync node in
  let* p = pass ~transport ?silence ?now node in
  if not p.wrote then Ok (first, p)
  else
    let* second = sync node in
    let* sent = Daily_digest.send ~transport node in
    Ok (second, { p with sent = p.sent @ sent })
