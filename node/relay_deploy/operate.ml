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

(* A digest line the deploy pass left (Deploy). A [lead] line leads the digest and is carried on
   every digest until the pass clears it; any other goes out once. *)
type note = { text : string; lead : bool; told : bool }

(* A deploy step that failed before the relay's Worker was replaced, kept with its cause and tried
   again at [retry_at] (Deploy). [attempts] counts the failed tries of [version], which the backoff
   doubles on. [notes] are what the digest says of it: one that went out stays, told, so a later try
   that meets the same cause does not say it again, and they all go with the pending step. *)
type pending = {
  step : string;
  why : string;
  retry_at : float;
  version : string;
  attempts : int;
  notes : note list;
}

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
      (** The relay release the relay last reported on GET /v0/version, absent
          for a Worker built before relay releases. *)
  pending : pending option;
  refused : refused list;
  told_not_operator : bool;
      (** The digest has said this node holds a token for a relay another member
          operates. *)
  token_refused : bool;
      (** Cloudflare said the token is wrong, expired or lacks a permission: no
          deploy is tried until operate stores a new one. *)
  notes : note list;
}

let notes_to_json notes : Yojson.Safe.t =
  `List
    (List.map
       (fun n ->
         `Assoc
           [
             ("text", `String n.text);
             ("lead", `Bool n.lead);
             ("told", `Bool n.told);
           ])
       notes)

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
                  ("notes", notes_to_json p.notes);
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
        ("notes", notes_to_json r.notes);
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
  let notes_of o =
    match field o "notes" with
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
              (fun retry_at ->
                { step; why; retry_at; version; attempts; notes = notes_of p })
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
      notes = notes_of j;
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

(* The home circle's address on the relay at [url], <url>/c/<root hex>: every read the operator's
   node makes of its home circle goes there, because the relay answers an unprefixed circle route
   410 circle_moved (docs/protocol.md, Hosted circles). *)
let home_address (n : Node.t) ~url =
  match Node.root n with
  | Some root -> Ok (Relay_client.circle_address url ~root)
  | None -> Error "this node holds no circle root"

(* The relay release a relay reports, on the unsigned GET /v0/version (Relay_client.version), which
   every supported relay release answers. None from a Worker that reports no version. *)
let reported_version transport ~url =
  match Relay_client.version transport ~base:url with
  | Ok v -> Ok v
  | Error e ->
      Error
        ("the relay at " ^ url ^ " did not answer GET /v0/version: "
        ^ Relay_client.error_to_string e)

(* Store the deploy token and the deployment record for [url], keeping what the deploy pass learned
   from an [existing] record for the same relay. *)
let store (n : Node.t) ~url ~existing ~serving ~reported (s : setup) =
  let* () = n.keystore.put token_name s.token in
  let record =
    match existing with
    | Some r ->
        (* A new token for the same relay: keep what the deploy pass has learned, and clear a
           wait on the old token. *)
        {
          r with
          url;
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
  Ok ()

(* A relay with no home, read unsigned before a first circle is founded on it (docs/design.md, Who
   may found a circle on a relay): refused home_set when its home already names a circle, since a
   relay has exactly one home. *)
let homeless ?(transport = Relay_client.curl) ~url () =
  match Relay_client.relay_info transport ~base:url with
  | Error e ->
      Error
        ("the relay at " ^ url ^ " did not answer GET /v0/relay ("
        ^ Relay_client.error_to_string e
        ^ "): a first circle is founded on a relay that hosts many circles")
  | Ok { home = Some h; _ } ->
      Error
        (Printf.sprintf
           "home_set: the relay at %s already has its home circle %s, and a \
            relay has exactly one; found from your circle there without \
            --relay, which vouches for the new one"
           url (Relay_url.short_root h))
  | Ok i -> Ok i

(* Write [root] into the relay's HOME_ROOT through Cloudflare's settings API with the deploy token,
   then wait until GET /v0/relay reports it as the relay's home. [root = None] clears it again. *)
let write_home ?(cloudflare = Cloudflare.curl) ?(form = Cloudflare.form_curl)
    ?(transport = Relay_client.curl) ?(wait = 90.) ~url (s : setup) root =
  let* () =
    cf
      (Cloudflare.set_var cloudflare form ~token:s.token
         ~account_id:s.account_id ~worker:s.worker ~name:"HOME_ROOT" root)
  in
  let deadline = Unix.gettimeofday () +. wait in
  let rec poll () =
    match Relay_client.relay_info transport ~base:url with
    | Ok i when i.home = root -> Ok ()
    | r ->
        if Unix.gettimeofday () > deadline then
          Error
            (Printf.sprintf
               "the relay at %s did not report %s as its home within %.0f \
                seconds (%s)"
               url
               (match root with
               | Some r -> Relay_url.short_root r
               | None -> "no home")
               wait
               (match r with
               | Ok i ->
                   "it reports "
                   ^ Option.fold ~none:"none" ~some:Relay_url.short_root i.home
               | Error e -> Relay_client.error_to_string e))
        else begin
          Unix.sleepf 2.;
          poll ()
        end
  in
  poll ()

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
  let* reported = reported_version transport ~url in
  let* () = store n ~url ~existing ~serving ~reported s in
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

(* Once this node reads its relays at the circle's address (Relay_addresses.rewrite), the relay it
   operates is known by that address too: its deployment record names it, and, when the circle reads
   this node as the relay's operator, the home circle's relay message is written again naming the
   address with the same body, so every other node adds it and the operator test keeps holding at
   the new url (docs/design.md, Moving the relays that run today). Answers what to say. *)
let readdress (n : Node.t) ~moved : (string list, string) result =
  let* existing = load n.dir in
  match existing with
  | None -> Ok []
  | Some r -> (
      match List.assoc_opt (normal_url r.url) moved with
      | None -> Ok []
      | Some address ->
          let f = Node.fold n in
          let operator = Fold.relay_operator f r.url in
          save n.dir { r with url = address };
          let* wrote =
            match (operator, identity n, Hashtbl.find_opt f.relays r.url) with
            | Some o, Some i, Some relay when o = i ->
                let* _ =
                  Node.write n ~kind:"relay"
                    (Bodies.make_relay ~url:address ~mailer:relay.mailer
                       ?encryption_key:relay.relay_encryption_key ())
                in
                Ok true
            | _ -> Ok false
          in
          Ok
            ([ "This node deploys " ^ address ^ ", its home circle's address." ]
            @
            if wrote then
              [ "The home circle's relay message now names " ^ address ^ "." ]
            else []))

(* THE CIRCLES A RELAY HOSTS (docs/design.md, Who may found a circle on a relay): `digestif relay
   circles`, `suspend` and `resume` on the operator's node, through Cloudflare's D1 query API with the
   deploy token it already holds. No admin route on the relay exists, and neither reads anything a
   circle holds. *)

type hosted = {
  root : string;
  opened_at : string;
  size : int;
  last_append_at : string option;
  vouched_by : string option;
  state : string;
}

(* The operator's record and token, or why this node cannot reach the relay's D1. *)
let operated_setup (n : Node.t) =
  let* record = load n.dir in
  match record with
  | None ->
      Error
        "this node deploys no relay; the operator's node runs this, set up \
         with digestif relay operate or digestif circle found --relay"
  | Some r -> (
      let* t = token n in
      match t with
      | None -> Error ("this node holds no deploy token for " ^ r.url)
      | Some token -> Ok (r, token))

let hosted_of_row (j : Yojson.Safe.t) =
  let str k =
    match j with
    | `Assoc f -> (
        match List.assoc_opt k f with Some (`String s) -> Some s | _ -> None)
    | _ -> None
  in
  let int k =
    match j with
    | `Assoc f -> (
        match List.assoc_opt k f with
        | Some (`Int i) -> i
        | Some (`Float x) -> int_of_float x
        | _ -> 0)
    | _ -> 0
  in
  match (str "root", str "opened_at", str "state") with
  | Some root, Some opened_at, Some state ->
      Some
        {
          root;
          opened_at;
          size = int "size";
          last_append_at = str "last_append_at";
          vouched_by = str "vouched_by";
          state;
        }
  | _ -> None

(* Every circle the relay this node operates hosts, oldest first. *)
let hosted_circles ?(cloudflare = Cloudflare.curl) (n : Node.t) =
  let* r, token = operated_setup n in
  let* results =
    cf
      (Cloudflare.d1_query cloudflare ~token ~account_id:r.account_id
         ~database_id:r.database_id
         "SELECT root, opened_at, size, last_append_at, vouched_by, state FROM \
          hosted_circles ORDER BY opened_at, root")
  in
  Ok (List.filter_map hosted_of_row (List.concat results))

let size_text b =
  let mib = float_of_int b /. 1048576. in
  if b < 1024 then Printf.sprintf "%d B" b
  else if mib < 1. then Printf.sprintf "%.0f KiB" (float_of_int b /. 1024.)
  else Printf.sprintf "%.1f MiB" mib

(* One line per circle: the root's short form, when it opened, its size, its last append, which
   circle vouched (home for the one that needed none) and its state. *)
let circle_line (h : hosted) =
  String.concat "\t"
    [
      Relay_url.short_root h.root;
      h.opened_at;
      size_text h.size;
      Option.value h.last_append_at ~default:"-";
      (match h.vouched_by with
      | Some v -> "vouched by " ^ Relay_url.short_root v
      | None -> "home");
      h.state;
    ]

(* The one hosted circle [prefix] names: the full 64 hex digits (or sha256:<hex>), or a prefix of at
   least 8 that names exactly one; refused ambiguous_root, listing each match, otherwise. *)
let resolve_root (circles : hosted list) prefix =
  let p = String.lowercase_ascii (Relay_url.root_hex (String.trim prefix)) in
  if String.length p < 8 then
    Error "name the circle by its root: at least its first 8 hex digits"
  else if
    not
      (String.for_all
         (fun c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
         p)
  then Error (prefix ^ " is not a root's hex digits")
  else
    match
      List.filter
        (fun h -> String.starts_with ~prefix:p (Relay_url.root_hex h.root))
        circles
    with
    | [ h ] -> Ok h
    | [] -> Error ("the relay hosts no circle " ^ p)
    | many ->
        Error
          ("ambiguous_root: " ^ p ^ " names "
          ^ String.concat ", "
              (List.map (fun h -> Relay_url.short_root h.root) many)
          ^ "; give more of the root")

(* Suspend ([to_ = "suspended"]) or resume ([to_ = "open"]) the circle [prefix] names: every route
   under its address answers 410 circle_suspended while it is suspended. Its log is untouched. *)
let set_circle_state ?(cloudflare = Cloudflare.curl) (n : Node.t) ~prefix ~to_ =
  let* r, token = operated_setup n in
  let* circles = hosted_circles ~cloudflare n in
  let* h = resolve_root circles prefix in
  if h.state = to_ then
    Ok (Printf.sprintf "%s is already %s" (Relay_url.short_root h.root) to_)
  else
    let root_hex = Relay_url.root_hex h.root in
    let* _ =
      cf
        (Cloudflare.d1_query cloudflare ~token ~account_id:r.account_id
           ~database_id:r.database_id
           (Printf.sprintf
              "UPDATE hosted_circles SET state = '%s', state_changed_at = '%s' \
               WHERE root = 'sha256:%s'"
              to_ (Time_fmt.now ()) root_hex))
    in
    Ok (Printf.sprintf "%s\t%s" (Relay_url.short_root h.root) to_)
