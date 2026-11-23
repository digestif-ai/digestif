(* An approval every admin signs with their release key (docs/protocol.md, approval): an invite,
   whose document is a digestif-admission-v0, or a signer-set change, whose document is a
   digestif-signers-v0. Each signature is Ed25519 over the kind's domain line and the document's
   exact bytes, the way a release manifest or a revocation is signed (docs/releases.md, The
   channel), so one release signature is never replayed as another kind's. *)

let admission_format = "digestif-admission-v0"
let admission_domain = "DIGESTIF-ADMISSION-V0\n"
let signers_format = "digestif-signers-v0"
let signers_domain = "DIGESTIF-SIGNERS-V0\n"

(* How long an approval waits for its last signature, judged from its created_at. *)
let lifetime_seconds = 7. *. 24. *. 3600.

type kind = Invite | Promotion | Removal | Replacement

let kind_to_string = function
  | Invite -> "invite"
  | Promotion -> "promotion"
  | Removal -> "removal"
  | Replacement -> "replacement"

let kind_of_string = function
  | "invite" -> Some Invite
  | "promotion" -> Some Promotion
  | "removal" -> Some Removal
  | "replacement" -> Some Replacement
  | _ -> None

(* The domain line a kind's document is signed over. *)
let domain = function
  | Invite -> admission_domain
  | Promotion | Removal | Replacement -> signers_domain

type signature = { key : string; signature : string }

(* An approval whose last signature is in: its envelope hash, its kind, the document's exact bytes
   and every signature over them. What the kind's effect takes (Invite_effect, Signer_set_effect). *)
type signed = {
  id : string;
  kind : kind;
  document : string;
  signatures : signature list;
}

(* ---- the wire: what an approval and an answer carry once opened (docs/protocol.md, approval) ---- *)

let ( let* ) = Result.bind
let get name = function `Assoc f -> List.assoc_opt name f | _ -> None

let str name j =
  match get name j with Some (`String s) when s <> "" -> Some s | _ -> None

let opt_field name = function Some v -> [ (name, `String v) ] | None -> []

(* The sealed plaintext of an approval. [document] is the document's exact bytes, carried in
   base64url; a promotion and a replacement carry none until the new key's holder signs first. A
   replacement names the key it takes out and the key it puts in, which its document does not exist
   to say yet. *)
type request = {
  kind : kind;
  created_at : string;
  member : string option;
      (** identity, on a promotion, a removal or a replacement *)
  document : string option;
  removed_key : string option;
  added_key : string option;
}

let request_to_json (r : request) : Yojson.Safe.t =
  `Assoc
    ([
       ("kind", `String (kind_to_string r.kind));
       ("created_at", `String r.created_at);
     ]
    @ opt_field "member" r.member
    @ opt_field "document" (Option.map B64url.encode r.document)
    @ opt_field "removed_key" r.removed_key
    @ opt_field "added_key" r.added_key)

let decode_document = function
  | None -> Ok None
  | Some d -> (
      match B64url.decode d with
      | Ok b -> Ok (Some b)
      | Error _ -> Error "a document that is not base64url")

let request_of_json j =
  let* kind =
    match Option.bind (str "kind" j) kind_of_string with
    | Some k -> Ok k
    | None -> Error "an unknown kind"
  in
  let* created_at =
    match str "created_at" j with
    | Some t when Time_fmt.to_unix t <> None -> Ok t
    | _ -> Error "no created_at"
  in
  let* document = decode_document (str "document" j) in
  let r =
    {
      kind;
      created_at;
      member = str "member" j;
      document;
      removed_key = str "removed_key" j;
      added_key = str "added_key" j;
    }
  in
  match kind with
  | Invite when document = None -> Error "an invite carries its admission"
  | Removal when document = None || r.member = None ->
      Error "a removal names its member and carries its set"
  | Promotion when r.member = None -> Error "a promotion names its member"
  | Replacement when r.removed_key = None || r.added_key = None ->
      Error "a replacement names both keys"
  | _ -> Ok r

(* The sealed plaintext of an approval_answer: a release-key signature over the document, the
   document itself on the new key's first signature, or a decline. *)
type reply =
  | Signature of { key : string; signature : string; completes : string option }
  | Decline

let reply_to_json : reply -> Yojson.Safe.t = function
  | Decline -> `Assoc [ ("answer", `String "decline") ]
  | Signature { key; signature; completes } ->
      `Assoc
        ([
           ("answer", `String "signature");
           ("key", `String key);
           ("signature", `String signature);
         ]
        @ opt_field "document" (Option.map B64url.encode completes))

let reply_of_json j =
  match str "answer" j with
  | Some "decline" -> Ok Decline
  | Some "signature" -> (
      match (str "key" j, str "signature" j) with
      | Some key, Some signature ->
          let* completes = decode_document (str "document" j) in
          Ok (Signature { key; signature; completes })
      | _ -> Error "a signature names its key and carries the signature")
  | _ -> Error "an unknown answer"

(* ---- the documents: a digestif-signers-v0 here, a digestif-admission-v0 in
   Digestif_invite.Approved_invite ---- *)

(* One entry of a signer set: its holder's name, the ed25519 admin key, and the circle identity of
   the admin who holds it (docs/protocol.md, circle), which a node and a relay read to tell a sitting
   admin from a member. An entry without one leaves its key unbound. *)
type signer = { name : string; key : string; identity : string option }

let signer_fields s =
  [ ("name", `String s.name); ("key", `String s.key) ]
  @ opt_field "identity" s.identity

(* A digestif-signers-v0 (docs/releases.md, Changing the signer set): the whole new set, each entry
   naming its holder's identity when the set binds one. *)
let signers_document ~created_at signers =
  Yojson.Safe.to_string
    (`Assoc
       [
         ("format", `String signers_format);
         ("created_at", `String created_at);
         ( "signers",
           `List (List.map (fun s -> `Assoc (signer_fields s)) signers) );
       ])

(* A digestif-admission-v0 (docs/protocol.md, Approvals): the invite every admin signs. Its body
   keeps the install command and expiry lines marked (Digestif_invite.Approved_invite). *)
let admission_document ~circle ~created_at ~guest_name ~guest_email ~role
    ~invite_key ~subject ~body =
  Yojson.Safe.to_string
    (`Assoc
       [
         ("format", `String admission_format);
         ("circle", `String circle);
         ("created_at", `String created_at);
         ( "guest",
           `Assoc
             [ ("name", `String guest_name); ("email", `String guest_email) ] );
         ("role", `String role);
         ("invite_key", `String invite_key);
         ("subject", `String subject);
         ("body", `String body);
       ])

let parse_json = Jcs.parse_unique

(* An entry's optional [identity]: absent, or an ed25519 key; anything else is an error. *)
let parse_identity s =
  match get "identity" s with
  | None -> Ok None
  | Some (`String i) -> (
      match Keys.parse_ed25519 i with
      | Ok i -> Ok (Some i)
      | Error _ -> Error "a signer's identity is an ed25519 key")
  | Some _ -> Error "a signer's identity is an ed25519 key"

(* The entries of a digestif-signers-v0 or a circle root's admins, in order. *)
let parse_signer_list l =
  List.fold_right
    (fun s acc ->
      let* acc = acc in
      match (str "name" s, Option.map Keys.parse_ed25519 (str "key" s)) with
      | Some name, Some (Ok key) ->
          let* identity = parse_identity s in
          Ok ({ name; key; identity } :: acc)
      | _ -> Error "every signer has a name and an ed25519 key")
    l (Ok [])

let parse_signers_json j =
  if str "format" j <> Some signers_format then Error ("not a " ^ signers_format)
  else
    match get "signers" j with
    | Some (`List l) -> parse_signer_list l
    | _ -> Error "no signers list"

let parse_signers bytes =
  let* j = parse_json bytes in
  parse_signers_json j

(* Whether [signature] by the release key [key] is over [kind]'s domain line and [document]. *)
let verifies ~kind ~document ~key ~signature =
  Keys.verify ~pub:key ~signature (domain kind ^ document)

(* The set a signer-set change names, held to the rule of a change (docs/releases.md, Changing the
   signer set: at least two keys, none twice) and to what its kind says it is against [current]:
   a promotion is [current] plus one key, a removal [current] less [removed], a replacement
   [current] with [removed] in place of [added]. Answers the key the document adds, which signs
   first, on a promotion and a replacement. *)
let check_set_change ~kind ~(current : signer list) ?removed ?added doc =
  let* signers = parse_signers doc in
  let keys = List.map (fun s -> s.key) signers in
  let cur = List.sort compare (List.map (fun s -> s.key) current) in
  let sorted = List.sort compare keys in
  let minus k l = List.filter (( <> ) k) l in
  let same a b = List.sort compare a = List.sort compare b in
  if List.length (List.sort_uniq compare keys) <> List.length keys then
    Error "the set names a key twice"
  else if List.length keys < 2 then Error "a signer set keeps at least two keys"
  else
    match (kind, removed, added) with
    | Promotion, _, _ -> (
        match List.filter (fun k -> not (List.mem k cur)) sorted with
        | [ k ] when same (minus k sorted) cur -> Ok (Some k)
        | _ -> Error "a promotion is the current set plus one key")
    | Removal, Some r, _ when List.mem r cur && same sorted (minus r cur) ->
        Ok None
    | Removal, _, _ -> Error "a removal is the current set less one key"
    | Replacement, Some r, Some a
      when List.mem r cur
           && (not (List.mem a cur))
           && same sorted (a :: minus r cur) ->
        Ok (Some a)
    | Replacement, _, _ ->
        Error
          "a replacement is the current set with one key in place of another"
    | Invite, _, _ -> Error "an invite is not a signer-set change"

(* ---- the fold: an approval's state from its answers (docs/protocol.md, approval_answer) ---- *)

(* Halted is never folded from the answers: the node that holds a revoked key in its signer set ends
   a waiting approval of a kind that does not lift the halt (Signer_halt.ends), and it keeps the
   state from then on. *)
type state = Waiting | Signed | Declined | Expired | Halted

let state_to_string = function
  | Waiting -> "waiting"
  | Signed -> "signed"
  | Declined -> "declined"
  | Expired -> "expired"
  | Halted -> "halted"

let state_of_string = function
  | "waiting" -> Some Waiting
  | "signed" -> Some Signed
  | "declined" -> Some Declined
  | "expired" -> Some Expired
  | "halted" -> Some Halted
  | _ -> None

(* One answer as the node holds it: its envelope hash, its author's identity and its time. *)
type answer = {
  a_hash : string;
  a_author : string;
  a_at : float;
  reply : reply;
}

type counted = {
  c_key : string;
  c_signature : string;
  c_author : string;  (** the identity that handed the node this signature *)
  c_at : float;
  c_hash : string;
}

type progress = {
  state : state;
  document : string option;
  needed : string list;  (** the keys whose signature it needs *)
  first : string option;
      (** the key that signs first, while the document waits on it *)
  counted : counted list;  (** oldest first *)
  ended_at : float option;
  last : string option;  (** the answer that ended it *)
  faults : int;  (** signatures it ignored: a key it does not need, or false *)
}

let expires_at created_at = created_at +. lifetime_seconds

(* Fold [answers] (any order) into the approval's state, in (time, hash) order. [readers] are the
   identities that may answer; [current] is the signer set the node holds; [first_author] is who
   completes a promotion's or a replacement's document (the member, the starter). A signature
   counts when its key is one the document needs and it verifies; a promotion's or a replacement's
   first counts only from the new key, carrying a document [check_set_change] accepts. Nothing
   counts after the seven days. *)
let fold (r : request) ~readers ~(current : signer list) ~first_author ~now
    answers =
  let cur = List.map (fun s -> s.key) current in
  let needed_for doc =
    match r.kind with
    | Invite -> cur
    | _ -> (
        match parse_signers doc with
        | Ok s ->
            List.sort_uniq compare (cur @ List.map (fun (s : signer) -> s.key) s)
        | Error _ -> cur)
  in
  let first_key = match r.kind with Replacement -> r.added_key | _ -> None in
  let start =
    {
      state = Waiting;
      document = r.document;
      needed = (match r.document with Some d -> needed_for d | None -> cur);
      first = first_key;
      counted = [];
      ended_at = None;
      last = None;
      faults = 0;
    }
  in
  let created = Option.value (Time_fmt.to_unix r.created_at) ~default:0. in
  let expiry = expires_at created in
  let fault p = { p with faults = p.faults + 1 } in
  let step p a =
    if
      p.state <> Waiting || a.a_at > expiry || not (List.mem a.a_author readers)
    then p
    else
      match a.reply with
      | Decline ->
          {
            p with
            state = Declined;
            ended_at = Some a.a_at;
            last = Some a.a_hash;
          }
      | Signature { key; signature; completes } -> (
          let count p document =
            let c =
              {
                c_key = key;
                c_signature = signature;
                c_author = a.a_author;
                c_at = a.a_at;
                c_hash = a.a_hash;
              }
            in
            let p = { p with counted = p.counted @ [ c ] } in
            let signed k = List.exists (fun c -> c.c_key = k) p.counted in
            if List.for_all signed p.needed then
              {
                p with
                state = Signed;
                ended_at = Some a.a_at;
                last = Some a.a_hash;
                document = Some document;
              }
            else { p with document = Some document }
          in
          match (p.document, completes) with
          | None, Some doc -> (
              match
                check_set_change ~kind:r.kind ~current ?removed:r.removed_key
                  ?added:r.added_key doc
              with
              | Ok (Some k)
                when k = key
                     && Some a.a_author = first_author
                     && verifies ~kind:r.kind ~document:doc ~key ~signature ->
                  count { p with needed = needed_for doc; first = None } doc
              | _ -> fault p)
          | None, None -> fault p
          | Some doc, _ ->
              if
                List.mem key p.needed
                && (not (List.exists (fun c -> c.c_key = key) p.counted))
                && verifies ~kind:r.kind ~document:doc ~key ~signature
              then count p doc
              else fault p)
  in
  let sorted =
    List.sort (fun a b -> compare (a.a_at, a.a_hash) (b.a_at, b.a_hash)) answers
  in
  let p = List.fold_left step start sorted in
  if p.state = Waiting && now >= expiry then
    { p with state = Expired; ended_at = Some expiry }
  else p

(* The approval once signed, what the kind's effect takes. *)
let signed_of ~id (r : request) (p : progress) =
  match (p.state, p.document) with
  | Signed, Some document ->
      Some
        {
          id;
          kind = r.kind;
          document;
          signatures =
            List.map
              (fun c -> { key = c.c_key; signature = c.c_signature })
              p.counted;
        }
  | _ -> None
