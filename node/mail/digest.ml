(* The daily digest (docs/protocol.md, The digest) and the mail request that carries its link
   secrets to the mailing relay (Mailer routes). *)

type section = { title : string; lines : string list }

type written = {
  signed : Yojson.Safe.t;  (** the digest's signed_envelope, appended to every relay *)
  hash : string;
  links : Link.t list;  (** keep the secrets only until the mail request is accepted *)
}

let section_json s =
  `Assoc [ ("title", `String s.title); ("lines", `List (List.map (fun l -> `String l) s.lines)) ]

let ask_json ~(ask_hash : string) (ask : Ask.t) (links : (Ask.choice * Link.t) list) =
  `Assoc
    [
      ("ask", `String ask_hash);
      ("title", `String ask.title);
      ("detail", `String ask.detail);
      ("on_no_answer", `String ask.on_no_answer);
      ("lapses_at", `String ask.lapses_at);
      ( "options",
        `List
          (List.map
             (fun ((c : Ask.choice), (l : Link.t)) ->
               `Assoc
                 ([ ("label", `String c.label) ]
                 @ (if c.recommended then [ ("recommended", `Bool true) ] else [])
                 @ [ ("link", `String (B64.encode l.id)) ]))
             links) );
    ]

(* Write the digest. [device_key], [seq], [prev] and [epoch] place it on the member's chain;
   [asks] pairs each ask's envelope hash with the ask; [member_key] and [mailer_key] are the raw
   X25519 public keys the email is sealed to. *)
let write ~device_key ~seq ?prev ~epoch ~created_at ~date ~to_ ~subject ~sections ~asks ~mail_key
    ~next_mail_seq ~member_key ~mailer_key () =
  let per_ask =
    List.map
      (fun (ask_hash, (ask : Ask.t)) ->
        ( ask_hash,
          ask,
          List.map
            (fun c ->
              ( c,
                Link.presign ~mail_key ~next_mail_seq ~member_key ~created_at ~epoch ~ask_hash ~ask
                  c ))
            ask.options ))
      asks
  in
  let email =
    `Assoc
      [
        ("to", `String to_);
        ("subject", `String subject);
        ("sections", `List (List.map section_json sections));
        ("asks", `List (List.map (fun (h, a, ls) -> ask_json ~ask_hash:h a ls) per_ask));
      ]
  in
  let links = List.concat_map (fun (_, _, ls) -> List.map snd ls) per_ask in
  let body =
    `Assoc
      [
        ("date", `String date);
        ("sealed", Seal.seal ~recipients:[ member_key; mailer_key ] email);
        ("links", `List (List.map Link.record links));
      ]
  in
  let signed, hash = Envelope.sign ~key:device_key ~seq ?prev ~created_at ~epoch ~kind:"digest" body in
  { signed; hash; links }

let mail_request ~mailer_key w =
  let links =
    List.map
      (fun (l : Link.t) ->
        `Assoc [ ("id", `String (B64.encode l.id)); ("secret", `String (B64.encode l.secret)) ])
      w.links
  in
  `Assoc
    [
      ("digest", `String w.hash);
      ("sealed", Seal.seal ~recipients:[ mailer_key ] (`Assoc [ ("links", `List links) ]));
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
                  match (List.assoc_opt id table, B64.decode id) with
                  | Some secret, Ok raw -> Ok ((k, `String (Link.url ~relay ~id:raw ~secret)) :: acc)
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
