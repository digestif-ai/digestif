(* Settling asks (docs/protocol.md, Asks and decisions). Every relay's decisions reach the log on
   sync; for each of this member's asks the node acts on the first decision it read, by any key of
   the member's identity, written before the ask lapsed, and records it. An ask nobody answered
   settles on its on_no_answer once it lapses. A settled ask never moves again; a later decision is
   shown beside it, never acted on. *)

open Digestif_core
open Digestif_mail

type ask = {
  hash : string;
  ask : Ask.t;
  outcome : Store.outcome option;
  decisions : (string * string) list;
      (** every decision read for it, in the order read: envelope hash, option
      *)
}

(* A key of [identity] that the fold lets speak for this envelope. *)
let ours (fold : Fold.t) ~identity (r : Log.row) =
  Fold.reads_content fold
    { Fold.hash = r.hash; envelope = r.signed.envelope; body = r.signed.body }
  && Fold.identity_of fold r.signed.envelope.author = Some identity

(* The member's asks with every decision read for each, oldest ask first. *)
let read (node : Node.t) (fold : Fold.t) =
  Store.ensure node.log;
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
        (List.filter_map
           (fun (r : Log.row) ->
             if not (ours fold ~identity r) then None
             else
               match r.signed.body with
               | None -> None
               | Some b -> (
                   match Ask.of_body ~priv b with
                   | Error _ -> None
                   | Ok ask ->
                       let ids =
                         List.map (fun (c : Ask.choice) -> c.id) ask.options
                       in
                       let mine =
                         List.filter_map
                           (fun (a, ((d : Log.row), option)) ->
                             if a = r.hash && List.mem option ids then
                               Some (d, option)
                             else None)
                           decisions
                       in
                       Some
                         {
                           hash = r.hash;
                           ask;
                           outcome = Store.outcome node.log r.hash;
                           decisions =
                             List.map
                               (fun ((d : Log.row), o) -> (d.hash, o))
                               mine;
                         }))
           (Log.of_kind node.log "ask"))

let lapsed ~now (ask : Ask.t) =
  match Time_fmt.to_unix ask.lapses_at with Some t -> now >= t | None -> true

(* Record an outcome for every ask that has none and can get one now. Returns the newly settled. *)
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
               let in_time (d, _) =
                 match Log.find node.log d with
                 | Some r -> (
                     match
                       ( Time_fmt.to_unix r.signed.envelope.created_at,
                         Time_fmt.to_unix a.ask.lapses_at )
                     with
                     | Some c, Some l -> c < l
                     | _ -> false)
                 | None -> false
               in
               let o : Store.outcome option =
                 match List.find_opt in_time a.decisions with
                 | Some (d, option) ->
                     Some
                       {
                         option;
                         decision = Some d;
                         source = Decided;
                         decided_at = at;
                       }
                 | None when lapsed ~now a.ask ->
                     Some
                       {
                         option = a.ask.on_no_answer;
                         decision = None;
                         source = Lapsed;
                         decided_at = at;
                       }
                 | None -> None
               in
               Option.map
                 (fun o ->
                   Store.record_outcome node.log ~ask:a.hash o;
                   { a with outcome = Some o })
                 o)
           asks)
