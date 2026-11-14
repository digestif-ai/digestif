(* An invite the admins signed takes effect (DES-85466; docs/protocol.md, Approvals).

   The starting admin's node made the invite key when it started the approval and keeps the secret
   half in its keystore, as a host's node keeps the code it emails. Once every admin signed the
   digestif-admission-v0, that node, and only that node, writes a dinner listing the guest with the
   signed admission beside the entry, counts the guest's 72 hours from then, and records the invite
   in the host's ledger (Host_watch) with the email exactly as the admins signed it. The email is
   shown with its two marked lines filled (Invite_email.fill), the install command and the expiry,
   which exist only once the dinner does. Writing is idempotent: a second call for the same
   approval, on this run or the next, finds the ledger record and writes nothing.

   An invite to the admin role is followed by a promotion: the guest's release key does not exist
   until they have a node, so once their join folds this node files the promotion through
   [file_promotion], exactly as Promote to Admin would, and records its id on the ledger record. *)

open Digestif_core

let ( let* ) = Result.bind
let ptime_now () = Option.get (Ptime.of_float_s (Unix.gettimeofday ()))

(* ---- the invite key, made when the approval starts ---- *)

let secret_name invite_key = "invite:" ^ invite_key

(* A fresh invite key for an approval this node starts: the secret half goes into the keystore under
   the public half's name, and the public half is what the admission document names. *)
let new_invite_key (node : Node.t) =
  let secret = Invite_code.random_secret () in
  let invite_key = Invite_code.invite_public_key { relay = ""; secret } in
  let* () = node.keystore.put (secret_name invite_key) (B64url.encode secret) in
  Ok invite_key

let invite_secret (node : Node.t) invite_key =
  match node.keystore.get (secret_name invite_key) with
  | Error e -> Error e
  | Ok None ->
      Error
        (Printf.sprintf
           "this node does not hold the secret half of invite key %s; only the \
            node that started the invite can write its dinner"
           invite_key)
  | Ok (Some s) -> (
      match B64url.decode (String.trim s) with
      | Ok secret when String.length secret = Invite_code.secret_bytes ->
          Ok secret
      | _ ->
          Error
            ("the keystore's invite secret for " ^ invite_key ^ " is malformed")
      )

(* ---- the digestif-admission-v0 document ---- *)

type admission = {
  circle : string;  (** sha256:<root dinner hash> *)
  created_at : string;
  guest : Dinner.guest;
  role : string;  (** member or admin *)
  invite_key : string;
  subject : string;
  body : string;  (** its install command and expiry lines still marked *)
}

let roles = [ "member"; "admin" ]

(* The document's exact bytes, as every admin signs them. *)
let document a =
  Yojson.Safe.to_string
    (`Assoc
       [
         ("format", `String Approval.admission_format);
         ("circle", `String a.circle);
         ("created_at", `String a.created_at);
         ( "guest",
           `Assoc
             [
               ("name", `String a.guest.name); ("email", `String a.guest.email);
             ] );
         ("role", `String a.role);
         ("invite_key", `String a.invite_key);
         ("subject", `String a.subject);
         ("body", `String a.body);
       ])

let parse_document bytes =
  let str j k =
    match j with
    | `Assoc fs -> (
        match List.assoc_opt k fs with
        | Some (`String s) -> Ok s
        | _ -> Error ("the admission has no string " ^ k))
    | _ -> Error "the admission is not an object"
  in
  match Yojson.Safe.from_string bytes with
  | exception Yojson.Json_error m -> Error ("the admission does not parse: " ^ m)
  | j ->
      let* format = str j "format" in
      let* () =
        if format = Approval.admission_format then Ok ()
        else Error ("the admission's format is " ^ format)
      in
      let* circle = str j "circle" in
      let* created_at = str j "created_at" in
      let g =
        match j with `Assoc fs -> List.assoc_opt "guest" fs | _ -> None
      in
      let* guest =
        match g with
        | Some g ->
            let* name = str g "name" in
            let* email = str g "email" in
            Ok { Dinner.name; email }
        | None -> Error "the admission names no guest"
      in
      let* role = str j "role" in
      let* () =
        if List.mem role roles then Ok ()
        else Error ("the admission's role is " ^ role)
      in
      let* invite_key = str j "invite_key" in
      let* subject = str j "subject" in
      let* body = str j "body" in
      let* () = Invite_email.check_marks body in
      Ok { circle; created_at; guest; role; invite_key; subject; body }

(* ---- writing the dinner ---- *)

(* Whether this node started approval [id]: its envelope's author is one of this node's own keys. *)
let started_here (node : Node.t) id =
  match Log.find node.log id with
  | None -> false
  | Some row -> List.mem row.signed.envelope.author (Node.own_keys node)

(* The circle's name, the root dinner's label, which a later dinner carries again. *)
let circle_label (node : Node.t) =
  match Option.bind (Node.root node) (Log.find node.log) with
  | Some { signed = { body = Some b; _ }; _ } -> (
      match Bodies.parse_dinner b with Ok d -> d.label | Error _ -> "")
  | _ -> ""

let utc_date t =
  let (y, m, d), _ = Ptime.to_date_time t in
  Printf.sprintf "%04d-%02d-%02d" y m d

let find_approved ledger id =
  List.find_opt
    (fun (r : Host_watch.record) ->
      match r.approved with Some a -> a.approval = id | None -> false)
    ledger

type outcome =
  | Wrote of { dinner_hash : string; record : Host_watch.record }
  | Already of Host_watch.record
      (** This approval's dinner is already written. *)
  | Not_starter  (** Another node started it; that node writes the dinner. *)
  | Not_invite

let write_dinner ~now (node : Node.t) ledger (s : Approval.signed) a =
  let* host =
    match Log.get_config node.log Node.k_identity with
    | Some h -> Ok h
    | None -> Error "this node has no identity; run digestif init"
  in
  let* () =
    if Node.root node = Some a.circle then Ok ()
    else Error "the admission names another circle than this node's"
  in
  let* secret = invite_secret node a.invite_key in
  let relays =
    List.map (fun (r : Log.relay_row) -> r.url) (Log.relays node.log)
  in
  let* relay =
    match relays with
    | r :: _ -> Ok r
    | [] -> Error "this node reads no relay to name in the invite"
  in
  let code = { Invite_code.relay; secret } in
  let* () =
    if Invite_code.invite_public_key code = a.invite_key then Ok ()
    else Error "the keystore's invite secret is not the admission's invite key"
  in
  let expires_at = Dinner.expiry ~now Dinner.default_ttl in
  let invite =
    {
      Dinner.guest = a.guest;
      code;
      invite_key = a.invite_key;
      expires_at;
      admission =
        Some { Bodies.document = s.document; signatures = s.signatures };
    }
  in
  let dinner =
    {
      Dinner.host;
      date = utc_date now;
      label = circle_label node;
      relays;
      invites = [ invite ];
    }
  in
  let* dinner_hash, _ = Node.write node ~kind:"dinner" (Dinner.body dinner) in
  let record =
    {
      Host_watch.dinner_hash;
      guest_name = a.guest.name;
      guest_email = a.guest.email;
      invite_key = a.invite_key;
      expires_at;
      message = "";
      state = Open Sent;
      approved =
        Some
          {
            approval = s.id;
            role = a.role;
            subject = a.subject;
            body = a.body;
            relay;
            promotion = None;
          };
    }
  in
  let* () = Host_watch.save node.dir (ledger @ [ record ]) in
  Ok (Wrote { dinner_hash; record })

(* The signed invite [s] takes effect on this node: on the node that started it, the dinner is
   written and the invite recorded; anywhere else nothing happens. *)
let take_effect ?(now = ptime_now ()) (node : Node.t) (s : Approval.signed) =
  match s.kind with
  | Promotion | Removal | Replacement -> Ok Not_invite
  | Invite -> (
      let* ledger = Host_watch.load node.dir in
      match find_approved ledger s.id with
      | Some r -> Ok (Already r)
      | None ->
          if not (started_here node s.id) then Ok Not_starter
          else
            let* a = parse_document s.document in
            write_dinner ~now node ledger s a)

(* The email the admins signed for [r], its install command and expiry filled in, to send to the
   guest. *)
let email (node : Node.t) (r : Host_watch.record) =
  match r.approved with
  | None -> Error (r.guest_name ^ "'s invite was not signed by the admins")
  | Some a ->
      let* secret = invite_secret node r.invite_key in
      Invite_email.of_signed
        ~to_:(Printf.sprintf "%s <%s>" r.guest_name r.guest_email)
        ~subject:a.subject ~body:a.body
        ~code:{ Invite_code.relay = a.relay; secret }
        ~expires_at:r.expires_at

(* ---- the promotion that follows an admin invite ---- *)

(* Files a promotion of [member] (an identity key) as Promote to Admin does, returning the
   approval's id. The node's approvals (ISS-87806) set it; until then filing refuses and the
   promotion stays due, so the next run files it. *)
let file_promotion : (Node.t -> member:string -> (string, string) result) ref =
  ref (fun (_ : Node.t) ~member:_ ->
      Error "this node cannot file a promotion yet (ISS-87806)")

(* Every admin invite whose guest joined and whose promotion is not filed yet. *)
let promotions_due (ledger : Host_watch.ledger) =
  List.filter_map
    (fun (r : Host_watch.record) ->
      match (r.approved, r.state) with
      | Some { role = "admin"; promotion = None; _ }, Joined { identity_key; _ }
        ->
          Some (r, identity_key)
      | _ -> None)
    ledger

type filed = {
  invite_key : string;
  guest : string;
  member : string;
  result : (string, string) result;
}

(* File every due promotion, recording each one filed on its ledger record. A promotion that could
   not be filed stays due and is tried again on the next run. *)
let file_promotions (node : Node.t) =
  let* ledger = Host_watch.load node.dir in
  match promotions_due ledger with
  | [] -> Ok []
  | due ->
      let results =
        List.map
          (fun ((r : Host_watch.record), member) ->
            {
              invite_key = r.invite_key;
              guest = r.guest_name;
              member;
              result = !file_promotion node ~member;
            })
          due
      in
      let filed_for invite_key =
        List.find_map
          (fun f ->
            match f.result with
            | Ok id when f.invite_key = invite_key -> Some id
            | _ -> None)
          results
      in
      let ledger =
        List.map
          (fun (r : Host_watch.record) ->
            match (r.approved, filed_for r.invite_key) with
            | Some a, Some id ->
                { r with approved = Some { a with promotion = Some id } }
            | _ -> r)
          ledger
      in
      let* () =
        if List.exists (fun f -> Result.is_ok f.result) results then
          Host_watch.save node.dir ledger
        else Ok ()
      in
      Ok results

(* ---- the invite page an admin's agent fills ---- *)

(* The local UI's invite composer (/members/invite), prefilled for one guest: To as one line, the
   role, and the host's own lines, which the composer puts under the greeting of the email it
   prefills (Invite_email.template). *)
let invite_page ~(guest : Dinner.guest) ~role ~message =
  Printf.sprintf "/members/invite?to=%s&role=%s&message=%s"
    (Invite_email.percent_encode
       (Printf.sprintf "%s <%s>" guest.name guest.email))
    (Invite_email.percent_encode role)
    (Invite_email.percent_encode message)
