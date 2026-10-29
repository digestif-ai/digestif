(* One pass of the daily acts, run after every sync: admit this machine's mail key once its device
   key is admitted, settle the asks decisions or lapses answer, write the digest when it is due,
   and send the mail requests whose digest the mailing relay holds. *)

open Digestif_core

type report = {
  mail_key : Mail_key.admission;
  settled : Decisions.ask list;
  digest : (Daily_digest.written option, string) result;
  sent : Daily_digest.sent list;
  wrote : bool;
      (** something new went into the log, so another sync should push it *)
}

let ( let* ) = Result.bind

let pass ?transport ?(now = Unix.gettimeofday ()) (node : Node.t) =
  let fold = Node.fold node in
  let* mail_key = Mail_key.admit node fold in
  let fold = match mail_key with Appended _ -> Node.fold node | _ -> fold in
  let* settled = Decisions.settle node fold ~now in
  let digest =
    if Daily_digest.due node ~now then
      Result.map Option.some (Daily_digest.write node ~now)
    else Ok None
  in
  let* sent = Daily_digest.send ?transport node in
  let wrote =
    (match mail_key with Appended _ -> true | _ -> false)
    || match digest with Ok (Some _) -> true | _ -> false
  in
  Ok { mail_key; settled; digest; sent; wrote }

(* Sync, run the pass, and when the pass wrote something sync again so it reaches every relay, then
   send the mail requests that sync made sendable. *)
let run ?(transport = Relay_client.curl) ?now (node : Node.t) =
  let* first = Sync.sync ~transport node in
  let* p = pass ~transport ?now node in
  if not p.wrote then Ok (first, p)
  else
    let* second = Sync.sync ~transport node in
    let* sent = Daily_digest.send ~transport node in
    Ok (second, { p with sent = p.sent @ sent })
