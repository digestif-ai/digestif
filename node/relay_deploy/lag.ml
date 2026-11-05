(* Reading relay versions and the lag lines (docs/releases.md, A relay left behind is named).

   Every sync, this node asks each relay it read cleanly for GET /v0/circle and records the
   relay_version it answers (absent on a Worker built before relay releases), beside the relay's url.

   A relay is BEHIND when it reports a version older than the newest relay release, or none, and
   has for at least the threshold since that release's announcement first reached this node (the
   earliest stored_at of an envelope carrying the newest release's document):

   - 2 days: the relay's operator's digest names it. The operator is the identity whose device
     authored the relay's newest relay message the fold applied (Who operates a relay).
   - 7 days: each release signer's digest names it, with its operator. A release signer's node is
     the one on the machine holding the signer's `digestif-update` config (Sign_next.config_path):
     the circle carries no tie between a release key and a member, and the signer signs on their
     own machine. A signer's own relay is their operator line's, not this one's.

   Each line is told once per release per relay per audience (relay_lag_told), so a relay is named
   again only when a newer release leaves it behind again. A relay reporting a version newer than
   every counting announcement, or one that is not a version, is a fault shown to the member, since
   only a signed release should be deployable. *)

open Digestif_core
module U = Digestif_update

let operator_days = 2.
let signer_days = 7.
let day = 86400.
let fault_kind = "relay_version"

let ensure (log : Log.t) =
  Log.exec log
    "CREATE TABLE IF NOT EXISTS relay_versions (url TEXT PRIMARY KEY, \
     relay_version TEXT, read_at TEXT NOT NULL)"
    [];
  Log.exec log
    "CREATE TABLE IF NOT EXISTS relay_lag_told (relay TEXT NOT NULL, version \
     TEXT NOT NULL, audience TEXT NOT NULL, told_at TEXT NOT NULL, PRIMARY KEY \
     (relay, version, audience))"
    []

(* The relay_version a GET /v0/circle answer carries: None when the field is absent or null. *)
let version_of_circle (j : Yojson.Safe.t) =
  match j with
  | `Assoc f -> (
      match List.assoc_opt "relay_version" f with
      | Some (`String s) when String.trim s <> "" -> Some (String.trim s)
      | _ -> None)
  | _ -> None

let store (log : Log.t) ~url (version : string option) =
  ensure log;
  Log.exec log
    "INSERT INTO relay_versions (url, relay_version, read_at) VALUES (?, ?, ?) \
     ON CONFLICT (url) DO UPDATE SET relay_version = excluded.relay_version, \
     read_at = excluded.read_at"
    [ Log.s url; Log.opt version; Log.s (Time_fmt.now ()) ]

(* What [url] last reported: None when it was never read, Some None when it reported no version. *)
let reported (log : Log.t) url : string option option =
  ensure log;
  match
    Log.rows log "SELECT relay_version FROM relay_versions WHERE url = ?"
      [ Log.s url ]
  with
  | [ [| v |] ] -> Some (Log.text_opt v)
  | _ -> None

(* A relay's reported version against the newest relay release. *)
type standing =
  | Current
  | Behind of string option  (** what it reports: a version, or none *)
  | Ahead of string
      (** newer than every counting announcement, or not a version *)

let standing ~(newest : U.Version.t option) (reported : string option) =
  match (reported, newest) with
  | None, None -> Current
  | None, Some _ -> Behind None
  | Some v, _ -> (
      match (U.Version.of_string v, newest) with
      | Error _, _ -> Ahead v
      | Ok _, None -> Ahead v
      | Ok r, Some n ->
          let c = U.Version.compare r n in
          if c < 0 then Behind (Some v) else if c = 0 then Current else Ahead v)

(* A relay's name in a line: its host. *)
let name url =
  let strip p s =
    if String.starts_with ~prefix:p s then
      String.sub s (String.length p) (String.length s - String.length p)
    else s
  in
  let rest = strip "http://" (strip "https://" url) in
  match String.index_opt rest '/' with
  | Some i -> String.sub rest 0 i
  | None -> rest

(* When the newest release's announcement first reached this node. *)
let announced_at (node : Node.t) (fold : Fold.t)
    (newest : U.Release.relay_manifest U.Release.signed) =
  let hashes =
    List.filter_map
      (fun (a : U.Circle_relay_release.announcement) ->
        match U.Circle_relay_release.of_body a.body with
        | Ok r when r.bytes = newest.bytes -> Some a.hash
        | _ -> None)
      (U.Circle_relay_release.applied node fold)
  in
  List.fold_left
    (fun acc h ->
      match
        Log.rows node.log "SELECT stored_at FROM envelopes WHERE hash = ?"
          [ Log.s h ]
      with
      | [ [| at |] ] -> (
          match Time_fmt.to_unix (Log.text at) with
          | Some t ->
              Some (match acc with Some a -> Float.min a t | None -> t)
          | None -> acc)
      | _ -> acc)
    None hashes

let told (log : Log.t) ~relay ~version ~audience =
  Log.rows log
    "SELECT 1 FROM relay_lag_told WHERE relay = ? AND version = ? AND audience \
     = ?"
    [ Log.s relay; Log.s version; Log.s audience ]
  <> []

let tell (log : Log.t) ~relay ~version ~audience () =
  ensure log;
  Log.exec log
    "INSERT OR IGNORE INTO relay_lag_told (relay, version, audience, told_at) \
     VALUES (?, ?, ?, ?)"
    [ Log.s relay; Log.s version; Log.s audience; Log.s (Time_fmt.now ()) ]

let runs = function
  | Some v -> "it runs " ^ v
  | None -> "it reports no relay version"

let days_ago ~now at =
  let d = int_of_float ((now -. at) /. day) in
  if d = 1 then "1 day ago" else Printf.sprintf "%d days ago" d

(* A relay ahead of every counting announcement is a fault for as long as it reports that. *)
let fault (log : Log.t) ~url = function
  | Ahead v ->
      Log.add_fault log ~kind:fault_kind ~author:url ~seq:0
        ~detail:
          (Printf.sprintf
             "%s reports relay version %s, which no relay release this node \
              counts announced"
             url v)
  | Current | Behind _ ->
      Log.resolve_faults log ~kind:fault_kind ~author:url ~seq:0

(* The relay releases the circle announces, under this node's signer set. *)
let releases (node : Node.t) fold =
  U.Circle_relay_release.from_circle
    ~state_path:(U.Schedule.state_path node.dir)
    node fold

let newest_version (t : U.Circle_relay_release.t) =
  Option.map
    (fun (r : U.Release.relay_manifest U.Release.signed) -> r.doc.relay_version)
    t.newest

(* Record what each relay reported at this sync, and the fault of a relay ahead of every counting
   announcement. A relay this sync could not read keeps what it last reported; so does one whose
   GET /v0/circle fails. *)
let record ?(transport = Relay_client.curl) (node : Node.t) (r : Sync.report) =
  match Node.device_key node with
  | Error _ -> ()
  | Ok key -> (
      List.iter
        (fun (rr : Sync.relay_report) ->
          if rr.error = None then
            match Relay_client.circle transport ~base:rr.relay ~key with
            | Ok j -> store node.log ~url:rr.relay (version_of_circle j)
            | Error _ -> ())
        r.relays;
      match releases node r.fold with
      | Error _ -> ()
      | Ok t ->
          let newest = newest_version t in
          List.iter
            (fun (relay : Log.relay_row) ->
              Option.iter
                (fun rep ->
                  fault node.log ~url:relay.url (standing ~newest rep))
                (reported node.log relay.url))
            (Log.relays node.log))

let is_signer () = Sys.file_exists (U.Sign_next.config_path ())

(* The lag lines this member's digest carries: their own relays 2 days behind, and, for a release
   signer, every other relay 7 days behind. *)
let digest_lines ?(is_signer = is_signer) (node : Node.t) ~now : Line.t list =
  let log = node.log in
  ensure log;
  let fold = Node.fold node in
  match releases node fold with
  | Error _ -> []
  | Ok releases ->
      let newest_v = newest_version releases in
      let since = Option.bind releases.newest (announced_at node fold) in
      let me = Log.get_config log Node.k_identity in
      let signer = lazy (is_signer ()) in
      List.concat_map
        (fun (relay : Log.relay_row) ->
          match reported log relay.url with
          | None -> []
          | Some rep -> (
              match (standing ~newest:newest_v rep, newest_v, since) with
              | Behind rep, Some nv, Some at ->
                  let version = U.Version.to_string nv in
                  let op = Fold.relay_operator fold relay.url in
                  let mine = op <> None && op = me in
                  let behind = now -. at in
                  let line ~audience text =
                    if told log ~relay:relay.url ~version ~audience then []
                    else
                      [
                        {
                          Line.text;
                          tell = tell log ~relay:relay.url ~version ~audience;
                        };
                      ]
                  in
                  if mine && behind >= operator_days *. day then
                    line ~audience:"operator"
                      (Printf.sprintf
                         "Your relay %s is behind: %s and the newest relay \
                          release is %s, announced %s. Run digestif relay \
                          status on your machine to see why."
                         (name relay.url) (runs rep) version (days_ago ~now at))
                  else if
                    (not mine)
                    && behind >= signer_days *. day
                    && Lazy.force signer
                  then
                    let by =
                      match
                        Option.bind op (fun id ->
                            Hashtbl.find_opt fold.cards id)
                      with
                      | Some (c, _) -> "operated by " ^ c.card_name
                      | None -> "whose operator the circle does not name"
                    in
                    line ~audience:"signer"
                      (Printf.sprintf
                         "The relay %s, %s, is behind: %s and the newest relay \
                          release is %s, announced %s."
                         (name relay.url) by (runs rep) version
                         (days_ago ~now at))
                  else []
              | _ -> []))
        (Log.relays log)
