(* Operating a relay (docs/releases.md, Who operates a relay): `digestif relay operate <url>` and
   `--remove`, the relay-deploy-token keystore entry and relay-deploy.json in the data directory,
   the token checks against Cloudflare, `digestif relay status`, and the operator test.

   A node operates a relay when both hold:
   1. the relay's newest relay message was authored by a device of this node's identity
      (Fold.relay_operator), a public fact of the circle every node reads the same way; and
   2. this node holds a deploy token and a deployment record for that relay's url, which only its
      operator could have put there.

   (2) without (1) deploys nothing and says so in the digest, once. (1) without (2) is an operator
   who has not set up deploys, which the lag lines reach (Lag). A node holds one deploy token, for
   one relay: no node holds a credential that could change a second relay. *)

let token_name = "relay-deploy-token"
let record_file = "relay-deploy.json"
let record_path dir = Filename.concat dir record_file

(* A deploy step that failed before the relay's Worker was replaced, kept with its cause and tried
   again at [retry_at] (Deploy). [attempts] counts the failed tries of [version], which the backoff
   doubles on. *)
type pending = {
  step : string;
  why : string;
  retry_at : float;
  version : string;
  attempts : int;
}

(* A digest line the deploy pass left (Deploy). A [lead] line leads the digest and is carried on
   every digest until the pass clears it; any other goes out once. *)
type note = { text : string; lead : bool; told : bool }

(* A relay release this relay will never be deployed again, and why (Deploy). *)
type refused = { version : string; why : string }

(* relay-deploy.json: everything about the deployment but the token. *)
type record = {
  url : string;
  account_id : string;
  worker : string;
  database_id : string;
  rollback_version_id : string;
      (** The Cloudflare Worker version a failed deploy goes back to: the one
          serving at setup, then the one serving before each deploy. *)
  reported_version : string option;
      (** The relay release the relay last reported on GET /v0/circle, absent
          for a Worker built before relay releases. *)
  pending : pending option;
  refused : refused list;
  told_not_operator : bool;
      (** The digest has said this node holds a token for a relay another member
          operates. *)
  token_refused : bool;
      (** Cloudflare answered 401 or 403 for the token: no deploy is tried until
          operate stores a new one. *)
  notes : note list;
}

let record_to_json r : Yojson.Safe.t =
  let opt name = function Some v -> [ (name, `String v) ] | None -> [] in
  `Assoc
    ([
       ("url", `String r.url);
       ("account_id", `String r.account_id);
       ("worker", `String r.worker);
       ("database_id", `String r.database_id);
       ("rollback_version_id", `String r.rollback_version_id);
     ]
    @ opt "reported_version" r.reported_version
    @ (match r.pending with
      | Some p ->
          [
            ( "pending",
              `Assoc
                [
                  ("step", `String p.step);
                  ("why", `String p.why);
                  ("retry_at", `String (Time_fmt.of_unix p.retry_at));
                  ("version", `String p.version);
                  ("attempts", `Int p.attempts);
                ] );
          ]
      | None -> [])
    @ [
        ( "refused",
          `List
            (List.map
               (fun (x : refused) ->
                 `Assoc
                   [ ("version", `String x.version); ("why", `String x.why) ])
               r.refused) );
        ("told_not_operator", `Bool r.told_not_operator);
        ("token_refused", `Bool r.token_refused);
        ( "notes",
          `List
            (List.map
               (fun n ->
                 `Assoc
                   [
                     ("text", `String n.text);
                     ("lead", `Bool n.lead);
                     ("told", `Bool n.told);
                   ])
               r.notes) );
      ])

let record_of_json (j : Yojson.Safe.t) : (record, string) result =
  let field f name =
    match f with `Assoc l -> List.assoc_opt name l | _ -> None
  in
  let str name =
    match field j name with
    | Some (`String s) when s <> "" -> Ok s
    | _ -> Error (record_file ^ " has no " ^ name)
  in
  let opt name =
    match field j name with Some (`String s) -> Some s | _ -> None
  in
  let ( let* ) = Result.bind in
  let* url = str "url" in
  let* account_id = str "account_id" in
  let* worker = str "worker" in
  let* database_id = str "database_id" in
  let* rollback_version_id = str "rollback_version_id" in
  let pending =
    match field j "pending" with
    | Some (`Assoc _ as p) -> (
        match (field p "step", field p "why", field p "retry_at") with
        | Some (`String step), Some (`String why), Some (`String at) ->
            let version =
              match field p "version" with Some (`String v) -> v | _ -> ""
            in
            let attempts =
              match field p "attempts" with Some (`Int i) -> i | _ -> 1
            in
            Option.map
              (fun retry_at -> { step; why; retry_at; version; attempts })
              (Time_fmt.to_unix at)
        | _ -> None)
    | _ -> None
  in
  let refused =
    match field j "refused" with
    | Some (`List l) ->
        List.filter_map
          (fun x ->
            match (field x "version", field x "why") with
            | Some (`String version), Some (`String why) ->
                Some { version; why }
            | _ -> None)
          l
    | _ -> []
  in
  let flag name = match field j name with Some (`Bool b) -> b | _ -> false in
  let notes =
    match field j "notes" with
    | Some (`List l) ->
        List.filter_map
          (fun x ->
            match field x "text" with
            | Some (`String text) ->
                let b name =
                  match field x name with Some (`Bool b) -> b | _ -> false
                in
                Some { text; lead = b "lead"; told = b "told" }
            | _ -> None)
          l
    | _ -> []
  in
  Ok
    {
      url;
      account_id;
      worker;
      database_id;
      rollback_version_id;
      reported_version = opt "reported_version";
      pending;
      refused;
      told_not_operator = flag "told_not_operator";
      token_refused = flag "token_refused";
      notes;
    }

(* The record, or None when this node has none. A file that does not parse is an error, never read
   as no record. *)
let load dir : (record option, string) result =
  let p = record_path dir in
  if not (Sys.file_exists p) then Ok None
  else
    match Yojson.Safe.from_file p with
    | j -> Result.map Option.some (record_of_json j)
    | exception (Yojson.Json_error m | Sys_error m) -> Error (p ^ ": " ^ m)

let save dir r =
  Digestif_update.State.write_atomic (record_path dir)
    (Yojson.Safe.pretty_to_string (record_to_json r) ^ "\n")

(* The deploy token, read from the keystore for one call. *)
let token (n : Node.t) = n.keystore.get token_name

(* Strip one trailing slash, so `https://x/` and `https://x` name one relay. *)
let normal_url u =
  if String.length u > 1 && String.ends_with ~suffix:"/" u then
    String.sub u 0 (String.length u - 1)
  else u

(* Whom the circle reads as operating [url], against this node's identity. *)
type standing =
  | Operates of record  (** both halves of the test hold *)
  | Not_operator of { record : record; operator : string option }
      (** a token and record, but the relay's newest relay message is another
          identity's ([operator]) or there is none *)
  | Not_set_up  (** no record, or no token *)

let identity (n : Node.t) = Log.get_config n.log Node.k_identity

(* The operator test, from its four facts: what the fold says operates the relay, this node's
   identity, the record, and whether the keystore holds a token. *)
let judge ~operator ~identity ~record ~token_held =
  match record with
  | None -> Not_set_up
  | Some _ when not token_held -> Not_set_up
  | Some record -> (
      match (operator, identity) with
      | Some o, Some i when o = i -> Operates record
      | _ -> Not_operator { record; operator })

let standing (n : Node.t) (f : Fold.t) : (standing, string) result =
  match load n.dir with
  | Error e -> Error e
  | Ok None -> Ok Not_set_up
  | Ok (Some r) -> (
      match token n with
      | Error e -> Error e
      | Ok t ->
          Ok
            (judge
               ~operator:(Fold.relay_operator f r.url)
               ~identity:(identity n) ~record:(Some r) ~token_held:(t <> None)))

(* The relays this node operates, by url: at most one. *)
let operated (n : Node.t) (f : Fold.t) : string list =
  match standing n f with Ok (Operates r) -> [ r.url ] | _ -> []

type setup = {
  account_id : string;
  worker : string;
  database_id : string;
  token : string;
}

let ( let* ) = Result.bind
let cf r = Result.map_error Cloudflare.error_to_string r

(* The token checks (docs/releases.md, Who operates a relay): the token is live, reads the Worker
   and the database, and sees no second Worker, which would mean the account holds more than this
   relay and the token could change it. *)
let check_token cloudflare (s : setup) =
  let token = s.token and account_id = s.account_id in
  let* () = cf (Cloudflare.verify_token cloudflare ~token ~account_id) in
  let* workers = cf (Cloudflare.workers cloudflare ~token ~account_id) in
  let* () =
    match List.filter (fun w -> w <> s.worker) workers with
    | [] when List.mem s.worker workers -> Ok ()
    | [] ->
        Error
          ("the token cannot see the Worker " ^ s.worker ^ " in account "
         ^ account_id)
    | others ->
        Error
          (Printf.sprintf
             "the token can see another Worker (%s) as well as %s: a relay's \
              account holds that relay and nothing else, so this token could \
              change more than the relay"
             (String.concat ", " others)
             s.worker)
  in
  let* () =
    cf
      (Cloudflare.database cloudflare ~token ~account_id
         ~database_id:s.database_id)
  in
  cf (Cloudflare.serving_version cloudflare ~token ~account_id ~worker:s.worker)

(* What the relay reports on a signed GET /v0/circle: its relay_version, absent on a Worker built
   before relay releases. *)
let reported_version transport (n : Node.t) ~url =
  let* key = Node.device_key n in
  match Relay_client.circle transport ~base:url ~key with
  | Error e ->
      Error
        ("the relay at " ^ url ^ " did not answer: "
        ^ Relay_client.error_to_string e)
  | Ok j -> (
      match j with
      | `Assoc f -> (
          match List.assoc_opt "relay_version" f with
          | Some (`String v) -> Ok (Some v)
          | _ -> Ok None)
      | _ -> Ok None)

(* `digestif relay operate <url>`: check the token, read what the relay runs, store the token and the
   record, and make the relay's newest relay message this node's when it is not. Nothing is stored
   until every check passed. Running it again for the same relay replaces the token. Returns what to
   print. *)
let operate ?(cloudflare = Cloudflare.curl) ?(transport = Relay_client.curl)
    (n : Node.t) ~url (s : setup) : (string list, string) result =
  let url = normal_url url in
  let f = Node.fold n in
  let* relay =
    match Hashtbl.find_opt f.relays url with
    | Some r -> Ok r
    | None ->
        Error
          ("the circle names no relay at " ^ url
         ^ "; a relay is added to the circle with digestif relay add --mine")
  in
  let* existing = load n.dir in
  let* () =
    match existing with
    | Some r when r.url <> url ->
        Error
          ("this node already deploys " ^ r.url
         ^ ", and a node holds the deploy token of one relay; run digestif \
            relay operate --remove " ^ r.url ^ " first")
    | _ -> Ok ()
  in
  let* serving = check_token cloudflare s in
  let* reported = reported_version transport n ~url in
  let* () = n.keystore.put token_name s.token in
  let record =
    match existing with
    | Some r ->
        (* A new token for the same relay: keep what the deploy pass has learned, and clear a
           wait on the old token. *)
        {
          r with
          account_id = s.account_id;
          worker = s.worker;
          database_id = s.database_id;
          rollback_version_id = serving;
          reported_version = reported;
          pending = None;
          told_not_operator = false;
          token_refused = false;
        }
    | None ->
        {
          url;
          account_id = s.account_id;
          worker = s.worker;
          database_id = s.database_id;
          rollback_version_id = serving;
          reported_version = reported;
          pending = None;
          refused = [];
          told_not_operator = false;
          token_refused = false;
          notes = [];
        }
  in
  save n.dir record;
  let* claimed =
    match (Fold.relay_operator f url, identity n) with
    | Some o, Some i when o = i -> Ok []
    | _, _ ->
        let* _ =
          Node.write n ~kind:"relay"
            (Bodies.make_relay ~url ~mailer:relay.mailer
               ?encryption_key:relay.relay_encryption_key ())
        in
        Ok
          [
            "The relay's newest relay message was not this node's, so this \
             node wrote it again with the same body; the next sync makes you \
             its operator.";
          ]
  in
  Ok
    ([
       "This node deploys " ^ url ^ " from each signed relay release.";
       "Worker " ^ s.worker ^ ", serving Cloudflare version " ^ serving
       ^ ", relay release "
       ^ Option.value reported ~default:"none reported"
       ^ ".";
     ]
    @ claimed)

(* `digestif relay operate --remove <url>`: delete the token and the record. *)
let remove (n : Node.t) ~url : (string list, string) result =
  let url = normal_url url in
  let* existing = load n.dir in
  match existing with
  | Some r when r.url <> url ->
      Error ("this node deploys " ^ r.url ^ ", not " ^ url)
  | _ ->
      let* () = n.keystore.delete token_name in
      (try Sys.remove (record_path n.dir) with Sys_error _ -> ());
      Ok
        [
          (match existing with
          | Some _ ->
              "This node no longer deploys " ^ url
              ^ ". Revoke the token in your Cloudflare dashboard too."
          | None -> "This node held no deploy record for " ^ url ^ ".");
        ]

let at t = Time_fmt.of_unix_local t

(* What `digestif relay status` prints: the record, the newest relay release, the deployed
   version, a pending step and its retry time, and refused versions, never the token. *)
let status (n : Node.t) ~(releases : Digestif_update.Circle_relay_release.t) :
    string list =
  let newest =
    match releases.newest with
    | Some r ->
        "newest relay release\t"
        ^ Digestif_update.Version.to_string r.doc.relay_version
    | None -> "newest relay release\tnone announced"
  in
  match standing n (Node.fold n) with
  | Error e -> [ newest; "operated relay\t" ^ e ]
  | Ok Not_set_up ->
      [
        newest;
        "operated relay\tnone; the relay's operator runs digestif relay \
         operate <url> on their own node";
      ]
  | Ok ((Operates r | Not_operator { record = r; _ }) as s) ->
      let operator =
        match s with
        | Operates _ -> "this node"
        | Not_operator { operator = Some o; _ } ->
            "another member (" ^ o
            ^ "), so this node deploys nothing; run digestif relay operate \
               --remove " ^ r.url ^ " if you no longer operate it"
        | _ ->
            "nobody: the circle carries no relay message for it, so this node \
             deploys nothing"
      in
      [
        newest;
        "relay\t" ^ r.url;
        "operator\t" ^ operator;
        "account\t" ^ r.account_id;
        "worker\t" ^ r.worker;
        "database\t" ^ r.database_id;
        "deployed version\t"
        ^ Option.value r.reported_version ~default:"none reported";
        "rollback target\tCloudflare version " ^ r.rollback_version_id;
        ("pending\t"
        ^
        match r.pending with
        | Some p ->
            Printf.sprintf "%s: %s; retry at %s" p.step p.why (at p.retry_at)
        | None -> "none");
        ("refused\t"
        ^
        match r.refused with
        | [] -> "none"
        | l ->
            String.concat "; "
              (List.map (fun (x : refused) -> x.version ^ " (" ^ x.why ^ ")") l)
        );
        ("token\tin the keystore as " ^ token_name
        ^
        if r.token_refused then
          "; Cloudflare refused it, so no deploy is tried until digestif relay \
           operate " ^ r.url ^ " stores a new one"
        else "");
      ]

(* The digest's line for a node holding a token for a relay another member operates, said once:
   telling it records it in relay-deploy.json, and operate clears it. *)
let digest_lines (n : Node.t) ~now:(_ : float) : Line.t list =
  match standing n (Node.fold n) with
  | Ok (Not_operator { record; _ }) when not record.told_not_operator ->
      [
        {
          Line.text =
            "This node holds the deploy token for " ^ record.url
            ^ ", but the circle does not name you as that relay's operator, so \
               this node deploys nothing. Run digestif relay operate --remove "
            ^ record.url ^ " if you no longer operate it.";
          tell = (fun () -> save n.dir { record with told_not_operator = true });
        };
      ]
  | _ -> []
