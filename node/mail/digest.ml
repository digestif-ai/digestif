(* The daily digest (docs/protocol.md, The digest) and the mail request that carries its link
   secrets to the mailing relay (Mailer routes). *)

open Digestif_core

type section = { title : string; lines : string list }

type written = {
  signed : Envelope.signed;
      (** the digest's signed_envelope, appended to every relay *)
  hash : string;
  links : Link.t list;
      (** keep the secrets only until the mail request is accepted *)
}

let section_json s =
  `Assoc
    [
      ("title", `String s.title);
      ("lines", `List (List.map (fun l -> `String l) s.lines));
    ]

(* ISS-52614 (docs/protocol.md, The digest): one entry of the digest's Inbox part, every Draft and
   New item of the member's. A draft and a question link to their page on the member's machine,
   where the words are read before anything is sent; a choice carries an answer link per option, a
   pre-signed pick; a notice carries an Acknowledge link, a pre-signed decision naming the option
   Ask.acknowledge. An entry with no envelope to answer (a local notice) links to its page. *)
type action =
  | Page of { label : string; url : string }
  | Pick of {
      keys : string list;  (** raw X25519 keys the pick is sealed to *)
      options : Ask.choice list;
      default : string option;
      deadline : string option;
    }
  | Acknowledge of { keys : string list }

type entry = {
  item : string;  (** the item's id on the member's node *)
  hash : string option;  (** its envelope, once sent *)
  kind : string;
  subject : string option;
  title : string;
  line : string;  (** who wrote it, to whom, and where it stands *)
  action : action;
}

(* The sentence the confirm and done pages show under an option that acts later than the click. *)
let pick_note ~subject (c : Ask.choice) =
  Ask.confirm_note
    {
      kind = subject;
      title = "";
      detail = "";
      about = None;
      options = [];
      on_no_answer = "";
      lapses_at = None;
    }
    c

(* Each entry with the links its options carry, presigned. An entry whose action needs an
   envelope and has none falls back to nothing to click. *)
let presign_entry ~mail_key ~next_mail_seq ~created_at ~epoch (e : entry) =
  let pick ~keys ?deadline ?note ~label option hash =
    Link.presign_pick ~mail_key ~next_mail_seq ~keys ~created_at ~epoch
      ~item:hash ?deadline ?note ~title:e.title ~label option
  in
  match (e.action, e.hash) with
  | Pick { keys; options; deadline; _ }, Some h ->
      List.map
        (fun (c : Ask.choice) ->
          ( c.id,
            pick ~keys ?deadline
              ?note:(pick_note ~subject:e.subject c)
              ~label:c.label c.id h ))
        options
  | Acknowledge { keys }, Some h ->
      [ (Ask.acknowledge, pick ~keys ~label:"Acknowledge" Ask.acknowledge h) ]
  | _ -> []

let entry_json (e : entry) (links : (string * Link.t) list) =
  let link id =
    Option.map
      (fun (l : Link.t) -> B64url.encode l.id)
      (List.assoc_opt id links)
  in
  let base =
    [
      ("item", `String e.item);
      ("kind", `String e.kind);
      ("title", `String e.title);
      ("line", `String e.line);
    ]
  in
  let action =
    match e.action with
    | Page { label; url } ->
        [ ("page", `Assoc [ ("label", `String label); ("url", `String url) ]) ]
    | Pick { options; default; deadline; _ } -> (
        [
          ( "options",
            `List
              (List.filter_map
                 (fun (c : Ask.choice) ->
                   Option.map
                     (fun l ->
                       `Assoc
                         ([ ("id", `String c.id); ("label", `String c.label) ]
                         @ (if c.recommended then
                              [ ("recommended", `Bool true) ]
                            else [])
                         @ [ ("link", `String l) ]))
                     (link c.id))
                 options) );
        ]
        @ (match default with
          | Some d -> [ ("default", `String d) ]
          | None -> [])
        @
        match deadline with
        | Some d -> [ ("deadline", `String d) ]
        | None -> [])
    | Acknowledge _ -> (
        match link Ask.acknowledge with
        | Some l -> [ ("acknowledge", `Assoc [ ("link", `String l) ]) ]
        | None -> [])
  in
  `Assoc (base @ action)

(* ISS-52614 (docs/protocol.md, The digest): one entry of the digest's Inbox part, every Draft and
   New item of the member's. A draft and a question link to their page on the member's machine,
   where the words are read before anything is sent; a choice carries an answer link per option, a
   pre-signed pick; a notice carries an Acknowledge link, a pre-signed decision naming the option
   Ask.acknowledge. An entry with no envelope to answer (a local notice) links to its page. *)
type action =
  | Page of { label : string; url : string }
  | Pick of {
      keys : string list;  (** raw X25519 keys the pick is sealed to *)
      options : Ask.choice list;
      default : string option;
      deadline : string option;
    }
  | Acknowledge of { keys : string list }

type entry = {
  item : string;  (** the item's id on the member's node *)
  hash : string option;  (** its envelope, once sent *)
  kind : string;
  subject : string option;
  title : string;
  line : string;  (** who wrote it, to whom, and where it stands *)
  action : action;
}

(* The sentence the confirm and done pages show under an option that acts later than the click. *)
let pick_note ~subject (c : Ask.choice) =
  Ask.confirm_note
    {
      kind = subject;
      title = "";
      detail = "";
      about = None;
      options = [];
      on_no_answer = "";
      lapses_at = None;
    }
    c

(* Each entry with the links its options carry, presigned. An entry whose action needs an
   envelope and has none falls back to nothing to click. *)
let presign_entry ~mail_key ~next_mail_seq ~created_at ~epoch (e : entry) =
  let pick ~keys ?deadline ?note ~label option hash =
    Link.presign_pick ~mail_key ~next_mail_seq ~keys ~created_at ~epoch
      ~item:hash ?deadline ?note ~title:e.title ~label option
  in
  match (e.action, e.hash) with
  | Pick { keys; options; deadline; _ }, Some h ->
      List.map
        (fun (c : Ask.choice) ->
          ( c.id,
            pick ~keys ?deadline
              ?note:(pick_note ~subject:e.subject c)
              ~label:c.label c.id h ))
        options
  | Acknowledge { keys }, Some h ->
      [ (Ask.acknowledge, pick ~keys ~label:"Acknowledge" Ask.acknowledge h) ]
  | _ -> []

let entry_json (e : entry) (links : (string * Link.t) list) =
  let link id =
    Option.map
      (fun (l : Link.t) -> B64url.encode l.id)
      (List.assoc_opt id links)
  in
  let base =
    [
      ("item", `String e.item);
      ("kind", `String e.kind);
      ("title", `String e.title);
      ("line", `String e.line);
    ]
  in
  let action =
    match e.action with
    | Page { label; url } ->
        [ ("page", `Assoc [ ("label", `String label); ("url", `String url) ]) ]
    | Pick { options; default; deadline; _ } -> (
        [
          ( "options",
            `List
              (List.filter_map
                 (fun (c : Ask.choice) ->
                   Option.map
                     (fun l ->
                       `Assoc
                         ([ ("id", `String c.id); ("label", `String c.label) ]
                         @ (if c.recommended then
                              [ ("recommended", `Bool true) ]
                            else [])
                         @ [ ("link", `String l) ]))
                     (link c.id))
                 options) );
        ]
        @ (match default with
          | Some d -> [ ("default", `String d) ]
          | None -> [])
        @
        match deadline with
        | Some d -> [ ("deadline", `String d) ]
        | None -> [])
    | Acknowledge _ -> (
        match link Ask.acknowledge with
        | Some l -> [ ("acknowledge", `Assoc [ ("link", `String l) ]) ]
        | None -> [])
  in
  `Assoc (base @ action)

(* Write the digest. [device_key], [seq], [prev] and [epoch] place it on the member's chain;
   [inbox] is its Inbox part; [member_key] and [mailer_key] are the raw X25519 public keys the
   email is sealed to. *)
let write ~device_key ~seq ?prev ~epoch ~created_at ~date ~to_ ~subject
    ~sections ?(inbox = []) ~mail_key ~next_mail_seq ~mailer_key ~member_key ()
    =
  let per_entry =
    List.map
      (fun e ->
        (e, presign_entry ~mail_key ~next_mail_seq ~created_at ~epoch e))
      inbox
  in
  let email =
    `Assoc
      ([
         ("to", `String to_);
         ("subject", `String subject);
         ("sections", `List (List.map section_json sections));
       ]
      @
      if per_entry = [] then []
      else
        [
          ("inbox", `List (List.map (fun (e, ls) -> entry_json e ls) per_entry));
        ])
  in
  let links = List.concat_map (fun (_, ls) -> List.map snd ls) per_entry in
  let body =
    `Assoc
      [
        ("date", `String date);
        ("sealed", Seal.seal ~recipients:[ member_key; mailer_key ] email);
        ("links", `List (List.map Link.record links));
      ]
  in
  let signed =
    Envelope.create ~key:device_key ~seq ?prev ~created_at ~epoch ~kind:"digest"
      body
  in
  { signed; hash = Envelope.hash signed.envelope; links }

let mail_request ~mailer_key w =
  let links =
    List.map
      (fun (l : Link.t) ->
        `Assoc
          [
            ("id", `String (B64url.encode l.id));
            ("secret", `String (B64url.encode l.secret));
          ])
      w.links
  in
  `Assoc
    [
      ("digest", `String w.hash);
      ( "sealed",
        Seal.seal ~recipients:[ mailer_key ] (`Assoc [ ("links", `List links) ])
      );
    ]

let ( let* ) = Result.bind

(* The mailing relay's half, written here so the node's tests and the conformance suite can check
   a digest end to end: open the digest and the request with the relay's key, and return the email
   plaintext with every option's link replaced by its URL. A Worker does the same in TypeScript. *)
let render ~mailer_priv ~relay ~digest_body ~request =
  let* sealed = Seal.member "sealed" digest_body in
  let* email = Seal.open_ ~priv:mailer_priv sealed in
  let* req_sealed = Seal.member "sealed" request in
  let* secrets = Seal.open_ ~priv:mailer_priv req_sealed in
  let* entries = Seal.member "links" secrets in
  let* table =
    match entries with
    | `List l ->
        List.fold_right
          (fun e acc ->
            let* acc = acc in
            let* id = Seal.string_member "id" e in
            let* secret = Seal.b64_member "secret" e in
            Ok ((id, secret) :: acc))
          l (Ok [])
    | _ -> Error "links is not a list"
  in
  let rec rewrite (j : Yojson.Safe.t) : (Yojson.Safe.t, string) result =
    match j with
    | `Assoc kvs ->
        let* kvs =
          List.fold_right
            (fun (k, v) acc ->
              let* acc = acc in
              match (k, v) with
              | "link", `String id -> (
                  match (List.assoc_opt id table, B64url.decode id) with
                  | Some secret, Ok raw ->
                      Ok ((k, `String (Link.url ~relay ~id:raw ~secret)) :: acc)
                  | _ -> Error ("no secret for link " ^ id))
              | _ ->
                  let* v = rewrite v in
                  Ok ((k, v) :: acc))
            kvs (Ok [])
        in
        Ok (`Assoc kvs)
    | `List l ->
        let* l =
          List.fold_right
            (fun v acc ->
              let* acc = acc in
              let* v = rewrite v in
              Ok (v :: acc))
            l (Ok [])
        in
        Ok (`List l)
    | j -> Ok j
  in
  rewrite email
