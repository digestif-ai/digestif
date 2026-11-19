(* The circle-state bodies (protocol.md, Circle-state bodies): builders that produce them with
   their inner signatures, and parsers the fold reads them with. *)

let ( let* ) = Result.bind
let get name = function `Assoc f -> List.assoc_opt name f | _ -> None

let str name j =
  match get name j with
  | Some (`String s) -> Ok s
  | _ -> Error ("missing string " ^ name)

let opt_str name j =
  match get name j with
  | Some (`String s) -> Ok (Some s)
  | None | Some `Null -> Ok None
  | _ -> Error ("bad " ^ name)

(* dinner *)

(* A guest entry's admission (protocol.md, dinner; Approvals): the digestif-admission-v0 document's
   exact bytes and every admin's release-key signature over them. A dinner after the circle's
   admission cutover records a guest only with one. *)
type admission = { document : string; signatures : Approval.signature list }

type guest = {
  name : string;
  invite_key : string;
  expires_at : string;
  admission : admission option;
}

let admission_json a : Yojson.Safe.t =
  `Assoc
    [
      ("document", `String (B64url.encode a.document));
      ( "signatures",
        `List
          (List.map
             (fun (s : Approval.signature) ->
               `Assoc
                 [ ("key", `String s.key); ("signature", `String s.signature) ])
             a.signatures) );
    ]

let parse_admission j =
  let* document = str "document" j in
  let* document =
    match B64url.decode document with
    | Ok d -> Ok d
    | Error _ -> Error "admission document is not base64url"
  in
  let* signatures =
    match get "signatures" j with
    | Some (`List l) ->
        List.fold_right
          (fun s acc ->
            let* acc = acc in
            let* key = str "key" s in
            let* signature = str "signature" s in
            Ok ({ Approval.key; signature } :: acc))
          l (Ok [])
    | _ -> Error "admission signatures"
  in
  Ok { document; signatures }

type dinner = {
  host : string;
  date : string;
  label : string;
  guests : guest list;
  relays : string list;
}

let dinner_json d : Yojson.Safe.t =
  `Assoc
    [
      ("host", `String d.host);
      ("dinner", `Assoc [ ("date", `String d.date); ("label", `String d.label) ]);
      ( "guests",
        `List
          (List.map
             (fun g ->
               `Assoc
                 ([
                    ("name", `String g.name);
                    ("invite_key", `String g.invite_key);
                    ("expires_at", `String g.expires_at);
                  ]
                 @
                 match g.admission with
                 | None -> []
                 | Some a -> [ ("admission", admission_json a) ]))
             d.guests) );
      ("relays", `List (List.map (fun r -> `String r) d.relays));
    ]

(* What a dinner and a circle root both carry: the host, the guests and the relays. *)
let parse_guest_list j =
  let* host = str "host" j in
  let* guests =
    match get "guests" j with
    | Some (`List gs) ->
        List.fold_right
          (fun g acc ->
            let* acc = acc in
            let* name = str "name" g in
            let* invite_key = str "invite_key" g in
            let* expires_at = str "expires_at" g in
            let* admission =
              match get "admission" g with
              | None | Some `Null -> Ok None
              | Some a -> Result.map Option.some (parse_admission a)
            in
            Ok ({ name; invite_key; expires_at; admission } :: acc))
          gs (Ok [])
    | None -> Ok []
    | _ -> Error "guests"
  in
  let relays =
    match get "relays" j with
    | Some (`List rs) ->
        List.filter_map (function `String s -> Some s | _ -> None) rs
    | _ -> []
  in
  Ok (host, guests, relays)

let parse_dinner j =
  let meta = Option.value (get "dinner" j) ~default:(`Assoc []) in
  let* date = str "date" meta in
  let label = Result.value (str "label" meta) ~default:"" in
  let* host, guests, relays = parse_guest_list j in
  Ok { host; date; label; guests; relays }

(* circle: the root of a circle founded on its own (protocol.md, circle). It names the circle and
   its founder, its [host], and may list first guests exactly as a dinner does. It has no date: a
   dinner is an event inside a circle, never what makes one. *)

let circle_json ?(admins = []) ~host ~name ~guests ~relays () : Yojson.Safe.t =
  match dinner_json { host; date = ""; label = name; guests; relays } with
  | `Assoc fields ->
      `Assoc
        (List.map
           (function
             | "dinner", _ -> ("circle", `Assoc [ ("name", `String name) ])
             | f -> f)
           fields
        @
        match admins with
        | [] -> []
        | l ->
            [
              ( "admins",
                `List
                  (List.map
                     (fun (s : Approval.signer) ->
                       `Assoc
                         [ ("name", `String s.name); ("key", `String s.key) ])
                     l) );
            ])
  | j -> j

(* A circle root's [admins] (protocol.md, circle): the circle's own signer set, which judges its
   later admissions in place of the release signers. None when the root names none, a dinner root
   included: that circle's admissions are judged by the release signer set. Each admin has a name
   and an ed25519 key, at least one, none twice. *)
let circle_admins ~kind j : (Approval.signer list option, string) result =
  match (kind, get "admins" j) with
  | "circle", Some (`List (_ :: _ as l)) ->
      let* admins =
        List.fold_right
          (fun a acc ->
            let* acc = acc in
            match (str "name" a, Result.bind (str "key" a) Keys.parse_ed25519) with
            | Ok name, Ok key -> Ok ({ Approval.name; key } :: acc)
            | _ -> Error "every admin has a name and an ed25519 key")
          l (Ok [])
      in
      let keys = List.map (fun (s : Approval.signer) -> s.key) admins in
      if List.length (List.sort_uniq String.compare keys) <> List.length keys
      then Error "the admins name a key twice"
      else Ok (Some admins)
  | "circle", Some _ -> Error "admins is a non-empty list"
  | _ -> Ok None

(* The envelope that lists invites, read as one shape whatever its kind: a dinner as parse_dinner
   reads it, or a circle root, whose name is the [label] and whose [date] is "", since no dinner
   founded it. *)
let parse_listing ~kind j =
  match kind with
  | "dinner" -> parse_dinner j
  | "circle" ->
      let meta = Option.value (get "circle" j) ~default:(`Assoc []) in
      let* name = str "name" meta in
      if String.trim name = "" then Error "a circle needs a name"
      else
        let* host, guests, relays = parse_guest_list j in
        Ok { host; date = ""; label = name; guests; relays }
  | k -> Error ("not a circle or a dinner: " ^ k)

(* join, authored by the invite key *)

type join = {
  dinner_hash : string;
  identity_key : string;
  identity_signature : string;
  device_key : string;
  device_signature : string;
}

let identity_claim ~dinner_hash ~identity_key : Yojson.Safe.t =
  `Assoc
    [ ("dinner", `String dinner_hash); ("identity_key", `String identity_key) ]

let device_claim ~identity_key ~key ~role : Yojson.Safe.t =
  `Assoc
    [
      ("identity_key", `String identity_key);
      ("key", `String key);
      ("role", `String role);
    ]

(* The join's device claim names its key `device_key`, unlike the device body's `key`. *)
let join_device_claim ~identity_key ~device_key : Yojson.Safe.t =
  `Assoc
    [
      ("identity_key", `String identity_key);
      ("device_key", `String device_key);
      ("role", `String "device");
    ]

let make_join ~(invite_key : Crypto.signing_key) ~dinner_hash
    ~(identity : Crypto.signing_key) ~(device : Crypto.signing_key) :
    Yojson.Safe.t =
  let identity_key = Keys.public identity and device_key = Keys.public device in
  `Assoc
    [
      ("dinner", `String dinner_hash);
      ("identity_key", `String identity_key);
      ( "identity_signature",
        `String
          (Keys.sign_json invite_key
             (identity_claim ~dinner_hash ~identity_key)) );
      ("device_key", `String device_key);
      ( "device_signature",
        `String
          (Keys.sign_json identity
             (join_device_claim ~identity_key ~device_key)) );
    ]

let parse_join j =
  let* dinner_hash = str "dinner" j in
  let* identity_key = str "identity_key" j in
  let* identity_signature = str "identity_signature" j in
  let* device_key = str "device_key" j in
  let* device_signature = str "device_signature" j in
  Ok
    {
      dinner_hash;
      identity_key;
      identity_signature;
      device_key;
      device_signature;
    }

(* Both inner signatures, against the invite key that authored the envelope. *)
let join_signatures_valid ~invite_key j =
  Keys.verify_json ~pub:invite_key ~signature:j.identity_signature
    (identity_claim ~dinner_hash:j.dinner_hash ~identity_key:j.identity_key)
  && Keys.verify_json ~pub:j.identity_key ~signature:j.device_signature
       (join_device_claim ~identity_key:j.identity_key ~device_key:j.device_key)

(* device *)

type role = Identity | Device | Mail

let role_to_string = function
  | Identity -> "identity"
  | Device -> "device"
  | Mail -> "mail"

let role_of_string = function
  | "device" -> Some Device
  | "mail" -> Some Mail
  | "identity" -> Some Identity
  | _ -> None

type device = {
  d_identity_key : string;
  key : string;
  role : role;
  signature : string;
}

let make_device ~(identity : Crypto.signing_key) ~key ~role : Yojson.Safe.t =
  let identity_key = Keys.public identity and r = role_to_string role in
  `Assoc
    [
      ("identity_key", `String identity_key);
      ("key", `String key);
      ("role", `String r);
      ( "signature",
        `String
          (Keys.sign_json identity (device_claim ~identity_key ~key ~role:r)) );
    ]

let parse_device j =
  let* d_identity_key = str "identity_key" j in
  let* key = str "key" j in
  let* r = str "role" j in
  let* role =
    match role_of_string r with
    | Some ((Device | Mail) as x) -> Ok x
    | _ -> Error ("role " ^ r)
  in
  let* signature = str "signature" j in
  Ok { d_identity_key; key; role; signature }

let device_signature_valid d =
  Keys.verify_json ~pub:d.d_identity_key ~signature:d.signature
    (device_claim ~identity_key:d.d_identity_key ~key:d.key
       ~role:(role_to_string d.role))

(* revoke: { target, by, after_seq, mail_read, signature }. [after_seq] maps each device key the revoke
   stops to the last seq of its honest chain; [mail_read] maps each mail key it stops to the hashes of
   its envelopes the revoker holds. Which keys a revoke stops is the fold's to say, so a key named here
   that the revoke does not stop is refused there; this parser refuses what the body alone shows. *)

type revoke = {
  target : string;
  by : string;
  after_seq : (string * int) list;
  mail_read : (string * string list) list;
  r_signature : string;
}

let after_seq_json after_seq : Yojson.Safe.t =
  `Assoc (List.map (fun (k, seq) -> (k, `Int seq)) after_seq)

let mail_read_json mail_read : Yojson.Safe.t =
  `Assoc
    (List.map
       (fun (k, hashes) -> (k, `List (List.map (fun h -> `String h) hashes)))
       mail_read)

let revoke_claim ~target ~by ~after_seq ~mail_read : Yojson.Safe.t =
  `Assoc
    [
      ("target", `String target);
      ("by", `String by);
      ("after_seq", after_seq_json after_seq);
      ("mail_read", mail_read_json mail_read);
    ]

let make_revoke ~(by : Crypto.signing_key) ~target ~after_seq ~mail_read :
    Yojson.Safe.t =
  let b = Keys.public by in
  `Assoc
    [
      ("target", `String target);
      ("by", `String b);
      ("after_seq", after_seq_json after_seq);
      ("mail_read", mail_read_json mail_read);
      ( "signature",
        `String
          (Keys.sign_json by (revoke_claim ~target ~by:b ~after_seq ~mail_read))
      );
    ]

let distinct_keys fields =
  List.length (List.sort_uniq compare (List.map fst fields))
  = List.length fields

let parse_after_seq j =
  match get "after_seq" j with
  | None -> Error "missing after_seq"
  | Some (`Assoc fields) when distinct_keys fields ->
      List.fold_right
        (fun (k, v) acc ->
          let* acc = acc in
          match v with
          | `Int seq when seq >= 0 -> Ok ((k, seq) :: acc)
          | _ -> Error ("after_seq " ^ k ^ " is not a non-negative integer"))
        fields (Ok [])
  | Some _ -> Error "after_seq is not an object of keys"

let parse_mail_read j =
  match get "mail_read" j with
  | None -> Error "missing mail_read"
  | Some (`Assoc fields) when distinct_keys fields ->
      List.fold_right
        (fun (k, v) acc ->
          let* acc = acc in
          let bad =
            Error ("mail_read " ^ k ^ " is not a list of envelope hashes")
          in
          match v with
          | `List hs ->
              let hashes =
                List.filter_map
                  (function
                    | `String h when Keys.is_hash h -> Some h | _ -> None)
                  hs
              in
              if List.length hashes = List.length hs then Ok ((k, hashes) :: acc)
              else bad
          | _ -> bad)
        fields (Ok [])
  | Some _ -> Error "mail_read is not an object of keys"

let parse_revoke j =
  let* target = str "target" j in
  let* by = str "by" j in
  let* after_seq = parse_after_seq j in
  let* mail_read = parse_mail_read j in
  let* r_signature = str "signature" j in
  Ok { target; by; after_seq; mail_read; r_signature }

let revoke_signature_valid r =
  Keys.verify_json ~pub:r.by ~signature:r.r_signature
    (revoke_claim ~target:r.target ~by:r.by ~after_seq:r.after_seq
       ~mail_read:r.mail_read)

(* card and relay *)

type card = { card_name : string; agent_name : string; encryption_key : string }

let make_card ~name ~agent_name ~encryption_key : Yojson.Safe.t =
  `Assoc
    [
      ("name", `String name);
      ("agent_name", `String agent_name);
      ("encryption_key", `String encryption_key);
    ]

let parse_card j =
  let* card_name = str "name" j in
  let* agent_name = str "agent_name" j in
  let* encryption_key = str "encryption_key" j in
  Ok { card_name; agent_name; encryption_key }

type relay = {
  url : string;
  mailer : bool;
  relay_encryption_key : string option;
}

let make_relay ~url ~mailer ?encryption_key () : Yojson.Safe.t =
  `Assoc
    ([ ("url", `String url); ("mailer", `Bool mailer) ]
    @
    match encryption_key with
    | Some k -> [ ("encryption_key", `String k) ]
    | None -> [])

let parse_relay j =
  let* url = str "url" j in
  let mailer = match get "mailer" j with Some (`Bool b) -> b | _ -> false in
  let* relay_encryption_key = opt_str "encryption_key" j in
  Ok { url; mailer; relay_encryption_key }

(* retract: { "target": "sha256:<envelope hash>" } *)

let make_retract ~target : Yojson.Safe.t = `Assoc [ ("target", `String target) ]
let parse_retract j = str "target" j
