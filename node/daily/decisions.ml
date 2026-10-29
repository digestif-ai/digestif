(* Settling asks (docs/protocol.md, Asks and decisions). Every relay's decisions reach the log on
   sync; for each open ask in the node's ask store (Asks) the node acts on the first decision it
   read for the envelope the digest appended, by any key of the member's identity, written before
   the ask lapsed, and records it there. An ask nobody answered settles on its on_no_answer once it
   lapses. A join ask's answer goes to the invite flow (Invite_node.answer), which writes the
   revoke. A settled ask never moves again; a later decision is shown beside it, never acted on. *)

open Digestif_core
open Digestif_mail

let ( let* ) = Result.bind

module Invite_node = Digestif_invite.Invite_node
module Host_watch = Digestif_invite.Host_watch

type source = Decided | Lapsed | Answered

type outcome = {
  option : string;
  decision : string option;  (** the decision envelope acted on *)
  source : source;
  decided_at : string;
}

type ask = {
  key : string;
  hash : string option;  (** the ask envelope a digest appended, once one has *)
  ask : Asks.t;
  outcome : outcome option;
  decisions : (string * string) list;
      (** every decision read for it, in the order read: envelope hash, option
      *)
  revoke : string option;  (** the revoke settling it wrote *)
}

let outcome_of (a : Asks.t) =
  match (a.answer, a.answered_via) with
  | Some option, via ->
      let decision, source =
        match via with
        | Some (Asks.Decision d) -> (Some d, Decided)
        | Some Lapse -> (None, Lapsed)
        | Some Person | None -> (None, Answered)
      in
      Some
        {
          option;
          decision;
          source;
          decided_at = Option.value a.answered_at ~default:"";
        }
  | None, _ -> None

(* A key of [identity] that the fold lets speak for this envelope. *)
let ours (fold : Fold.t) ~identity (r : Log.row) =
  Fold.reads_content fold
    { Fold.hash = r.hash; envelope = r.signed.envelope; body = r.signed.body }
  && Fold.identity_of fold r.signed.envelope.author = Some identity

(* The member's asks with every decision read for each, oldest ask first. *)
let read (node : Node.t) (fold : Fold.t) =
  match (Log.get_config node.log Node.k_identity, Node.encryption_key node) with
  | None, _ -> Error "no identity; run digestif init"
  | _, Error e -> Error e
  | Some identity, Ok enc ->
      let priv = enc.secret in
      let decisions =
        List.filter_map
          (fun (r : Log.row) ->
            if not (ours fold ~identity r) then None
            else
              match r.signed.body with
              | None -> None
              | Some b -> (
                  match Ask.decision_of_body ~priv b with
                  | Ok (ask, option) ->
                      (* A mail key's answer names its ask as prev too; one that disagrees is not one. *)
                      let mail =
                        Fold.is_chainless fold r.signed.envelope.author
                      in
                      if mail && r.signed.envelope.prev <> Some ask then None
                      else Some (ask, (r, option))
                  | Error _ -> None))
          (Log.of_kind node.log "decision")
      in
      Ok
        (List.map
           (fun (a : Asks.t) ->
             let ids = List.map (fun (c : Asks.choice) -> c.id) a.options in
             let mine =
               match a.envelope with
               | None -> []
               | Some hash ->
                   List.filter_map
                     (fun (h, ((d : Log.row), option)) ->
                       if h = hash && List.mem option ids then
                         Some (d.hash, option)
                       else None)
                     decisions
             in
             {
               key = a.key;
               hash = a.envelope;
               ask = a;
               outcome = outcome_of a;
               decisions = mine;
               revoke = None;
             })
           (Asks.list ~all:true node.log))

(* The device key may sign a join ask's revoke itself while the fold still lets the device key that
   wrote the dinner revoke the identity its join admitted. Past that window revoking takes the
   phrase, so the ask stays open, and lapsed, for the person. *)
let device_revoke (node : Node.t) (fold : Fold.t) ~now (a : Asks.t) () =
  let* device = Node.device_key node in
  let target = Option.value a.about ~default:"" in
  match Hashtbl.find_opt fold.joins target with
  | Some (dinner, joined_at)
    when Hashtbl.find_opt fold.dinner_authors dinner = Some (Keys.public device)
         && now <= joined_at +. Fold.host_device_window ->
      Ok device
  | _ ->
      Error
        (Printf.sprintf
           "revoking %s takes the recovery phrase: digestif asks answer %s \
            revoke"
           target a.key)

(* Record [choice] for an open ask: a join ask through the invite flow, which also writes its
   revoke, any other in the ask store. *)
let act (node : Node.t) (fold : Fold.t) ~now ~via ~answered_at (a : Asks.t)
    choice =
  if Host_watch.invite_key_of_ask_key a.key <> None then
    Invite_node.answer ~via ~answered_at node ~key:a.key ~choice
      ~identity:(device_revoke node fold ~now a)
  else
    Result.map
      (fun () -> None)
      (Asks.record_answer node.log ~answered_at ~via ~key:a.key choice)

let in_time (node : Node.t) (a : Asks.t) (d, _) =
  match Log.find node.log d with
  | Some r -> (
      match
        ( Time_fmt.to_unix r.signed.envelope.created_at,
          Time_fmt.to_unix a.lapses_at )
      with
      | Some c, Some l -> c < l
      | _ -> false)
  | None -> false

(* Record an outcome for every ask that has none and can get one now. Returns the newly settled.
   An ask whose answer cannot be acted on yet (a join revoke past the device's window) stays open. *)
let settle (node : Node.t) (fold : Fold.t) ~now =
  match read node fold with
  | Error e -> Error e
  | Ok asks ->
      let at = Time_fmt.of_unix now in
      Ok
        (List.filter_map
           (fun a ->
             if a.outcome <> None then None
             else
               let choice =
                 match List.find_opt (in_time node a.ask) a.decisions with
                 | Some (d, option) -> Some (option, Asks.Decision d)
                 | None when Asks.lapsed ~now:at a.ask ->
                     Some (a.ask.on_no_answer, Asks.Lapse)
                 | None -> None
               in
               Option.bind choice (fun (option, via) ->
                   match
                     act node fold ~now ~via ~answered_at:at a.ask option
                   with
                   | Error _ -> None
                   | Ok revoke ->
                       let ask =
                         Option.value (Asks.find node.log a.key) ~default:a.ask
                       in
                       Some { a with ask; outcome = outcome_of ask; revoke }))
           asks)
