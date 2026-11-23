(* digestif-update remove <identity> (docs/protocol.md, revoke; docs/design.md, Member review): an
   admin removes a member with a revoke signed by their admin key. The node never holds the key: it
   answers the revoke's claim (the target, the key and the cutoffs its log holds once every relay is
   fetched), this module shows it, asks once, signs it in memory and hands the signature back, and
   the node posts the revoke with its own device key. A member whose identity a key of the signer
   set is bound to is a sitting admin and is refused before anything is signed: their key leaves the
   set first, by a removal approval. *)

let ( let* ) = Result.bind

type draft = {
  target : string;
  by : string;
  name : string;
  after_seq : (string * int) list;
  mail_read : (string * string list) list;
}

let parse_draft j =
  let* target = Approve.str "target" j in
  let* by = Approve.str "by" j in
  let* name =
    match Release.field "member" j with
    | Some m -> Approve.str "name" m
    | None -> Ok target
  in
  let* revoke =
    (* The draft's cutoffs read the way a revoke body's are, with a placeholder signature. *)
    Bodies.parse_revoke
      (`Assoc
         [
           ("target", `String target);
           ("by", `String by);
           ( "after_seq",
             Option.value (Release.field "after_seq" j) ~default:`Null );
           ( "mail_read",
             Option.value (Release.field "mail_read" j) ~default:`Null );
           ("signature", `String "");
         ])
  in
  Ok
    {
      target;
      by;
      name;
      after_seq = revoke.after_seq;
      mail_read = revoke.mail_read;
    }

let claim d =
  Bodies.revoke_claim ~target:d.target ~by:d.by ~after_seq:d.after_seq
    ~mail_read:d.mail_read

(* The member [identity] names, as the node holds them: their name, or why there is none. *)
let member ~(api : Approve.api) identity =
  let path = "/api/v0/members/" ^ identity in
  let* status, j = api ~meth:"GET" ~path ~body:None in
  if status = 404 then
    Error
      (Printf.sprintf
         "this node reads no member %s; copy the identity from their member \
          page or the review item"
         identity)
  else if status <> 200 then
    Error (Approve.error_message ~meth:"GET" ~path status j)
  else Approve.str "name" j

(* A sitting admin is refused here, before the node is asked for anything: the signer set binds a
   key to their identity, and a revoke of them would halt every admission and release while it
   stood (GOVERNANCE.md). *)
let refuse_sitting_admin ~set ~identity ~name =
  match
    List.find_opt
      (fun (k : Approve.set_key) ->
        k.set_identity = Some identity && not k.revoked)
      set
  with
  | None -> Ok ()
  | Some k ->
      Error
        (Printf.sprintf
           "%s still holds the admin key %s in the signer set; nothing was \
            signed. Take it out first: Remove as Admin on their member page, \
            then every admin signs that removal with digestif-update approve \
            <id>. Once it is signed, run digestif-update remove %s again."
           name k.set_key identity)

let remove_as ~(api : Approve.api) ~me ~read_secret ~ask ~say identity =
  let identity = String.trim identity in
  let* name = member ~api identity in
  let* set = Approve.signer_set api in
  let* () = refuse_sitting_admin ~set ~identity ~name in
  let* () =
    if Approve.in_set ~me set then Ok ()
    else
      Error
        (Printf.sprintf
           "your key %s is not in this circle's signer set; only an admin \
            removes a member, and nothing was signed"
           me)
  in
  let path = "/api/v0/members/" ^ identity ^ "/revocation_drafts" in
  let* status, j =
    api ~meth:"POST" ~path ~body:(Some (`Assoc [ ("by", `String me) ]))
  in
  let* () =
    if status = 201 then Ok ()
    else Error (Approve.error_message ~meth:"POST" ~path status j)
  in
  let* d =
    Result.map_error
      (fun e -> "the revoke the node drafted: " ^ e)
      (parse_draft j)
  in
  let* () =
    if d.target = identity && d.by = me then Ok ()
    else
      Error
        (Printf.sprintf
           "the node drafted a revoke of %s by %s, not of %s by your key; \
            nothing was signed"
           d.target d.by identity)
  in
  say (Printf.sprintf "Remove %s from the circle" name);
  say ("  identity:  " ^ identity);
  say ("  admin key: " ^ me);
  List.iter
    (fun (k, seq) ->
      say (Printf.sprintf "  device %s: kept up to seq %d" k seq))
    d.after_seq;
  List.iter
    (fun (k, hashes) ->
      say
        (Printf.sprintf "  mail key %s: %d envelopes kept" k
           (List.length hashes)))
    d.mail_read;
  say "";
  say
    (name
   ^ " reads Revoked on every node, and a revoked identity never returns: they \
      come back only by a new invite, as a new member.");
  if
    not
      (Approve.affirmative
         (ask (Printf.sprintf "Remove %s with %s? [y/N] " name me)))
  then (
    say "nothing was signed";
    Ok ())
  else
    let* secret = read_secret () in
    let* () =
      if Keys.public secret = me then Ok ()
      else
        Error
          (Printf.sprintf
             "your key is %s but the key asked about is %s; nothing was signed"
             (Keys.public secret) me)
    in
    let signature = Keys.sign_json secret (claim d) in
    let path = "/api/v0/members/" ^ identity ^ "/revocations" in
    let body =
      `Assoc
        [
          ("by", `String me);
          ("after_seq", Bodies.after_seq_json d.after_seq);
          ("mail_read", Bodies.mail_read_json d.mail_read);
          ("signature", `String signature);
        ]
    in
    let* status, j = api ~meth:"POST" ~path ~body:(Some body) in
    if status <> 201 then
      Error (Approve.error_message ~meth:"POST" ~path status j)
    else (
      say
        (Printf.sprintf
           "removed: %s reads Revoked, and this node posts the revoke to the \
            circle on its next sync"
           name);
      Ok ())

(* remove_as with a key already in memory. *)
let remove ~(api : Approve.api) ~secret ~ask ~say identity =
  remove_as ~api ~me:(Keys.public secret)
    ~read_secret:(fun () -> Ok secret)
    ~ask ~say identity
