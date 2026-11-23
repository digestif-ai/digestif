(* ISS-88004 (DES-85466, an invite takes effect): once every admin signed an invite, the starting
   admin's node writes its dinner and keeps the email the admins signed (Approved_invite). The node
   cannot send that email: it goes from the admin's own address, so the guest recognizes who it is
   from. So the node puts it in front of the admin as a notice, Send <guest>'s invite, one per
   invite, raised for every signed invite in the host's ledger that is still open and unexpired
   (Digest_lines.sync_send_invites).

   The notice is local (Item.local_subject): the email carries the install command, whose invite
   code is the invite key's secret half. Like the ledger, the notice never stores the filled email:
   it records which invite it is for, and the item's page renders the email from the ledger and the
   keystore when it is shown ([email]). It is settled (resolved) once the admin marks it sent, or
   once the guest joined, the invite was revoked or its 72 hours ran out, and stays in the Inbox
   until archived. *)

open Digestif_core
module Inv = Digestif_invite

let subject = "send_invite"

(* The invite a notice is for, kept for as long as the notice exists, so its page can show the
   email after it is settled too. *)
let k_invite id = "send_invite_notice:" ^ id

(* That an invite's notice was raised: never raised twice for one invite. *)
let k_told invite_key = "digest_told_send_invite:" ^ invite_key

let title (r : Inv.Host_watch.record) =
  Printf.sprintf "Send %s's invite." r.guest_name

let detail (r : Inv.Host_watch.record) =
  Printf.sprintf
    "Send the email below to %s from your own address, then mark it sent. The \
     invite works until %s."
    r.guest_email
    (Inv.Invite_email.readable_expiry r.expires_at)

(* Every invite the admins signed that is still to be sent: no join or revoke on it yet, and its 72
   hours not run out. *)
let due (ledger : Inv.Host_watch.ledger) ~now =
  List.filter
    (fun (r : Inv.Host_watch.record) ->
      r.approved <> None
      && (match r.state with Open -> true | Joined _ | Revoked _ -> false)
      && Ptime.is_later r.expires_at ~than:now)
    ledger

let told (log : Log.t) invite_key = Store.config log (k_told invite_key) <> None

let record (log : Log.t) ~id ~invite_key =
  Store.set_config log (k_invite id) invite_key;
  Store.set_config log (k_told invite_key) id

let invite_of (log : Log.t) id = Store.config log (k_invite id)

(* The open Send invite notices, each with the invite it is for when it recorded one. *)
let open_notices (log : Log.t) =
  Log.rows log
    "SELECT id FROM ui_items WHERE kind = 'notice' AND voice = 'node' AND \
     subject = ? AND done IS NULL"
    [ Log.s subject ]
  |> List.filter_map (function
    | [| id |] ->
        let id = Log.text id in
        Some (id, invite_of log id)
    | _ -> None)

(* The email notice [id] asks the admin to send, its install command and expiry filled in. None
   when [id] is no Send invite notice; an error when its invite is gone from the ledger or the
   keystore no longer holds the invite's secret half. *)
let email (node : Node.t) id =
  Option.map
    (fun invite_key ->
      Result.bind (Inv.Host_watch.load node.dir) (fun ledger ->
          match
            List.find_opt
              (fun (r : Inv.Host_watch.record) -> r.invite_key = invite_key)
              ledger
          with
          | None -> Error "this invite is no longer in the host's ledger"
          | Some r -> Inv.Approved_invite.email node r))
    (invite_of node.log id)

let email_json (e : Inv.Invite_email.t) : Yojson.Safe.t =
  `Assoc
    [
      ("to", `String e.to_);
      ("subject", `String e.subject);
      ("text", `String e.text);
      ("mailto", `String (Inv.Invite_email.mailto e));
    ]
