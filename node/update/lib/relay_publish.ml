(* Publishing a relay release (docs/releases.md, Publishing a relay release): `ci/release.sh
   relay-publish --version X`, which runs `digestif-update relay-publish`, and `sign --next` itself
   when the signature it just uploaded completes the signer set. Three steps, each safe to run
   again:

   1. Download the draft's manifest and every signature and check them as a node does
      (Policy.check_relay against this binary's signer set), so nothing is published that a node
      would not count.
   2. Publish the GitHub release, never as Latest (Latest is the node line to the install script
      and to the signing line), and write the manifest and the combined manifest.sig.json under
      relay/ on the channel branch, with relay/index.json listing it, in one commit.
   3. Write the announcement, a relay_release circle message, through this machine's node for its
      next sync to carry, exactly as a recall posts a release_recall; on a machine running no node,
      print the line that posts it from one that does.

   Everything on GitHub goes through the signer's own gh login and the channel commit through
   their own git, passed in, so the flow is tested without the network. *)

let ( let* ) = Result.bind

type announced =
  | Posted of string
      (** The envelope's hash; the node's next sync carries it. *)
  | Already_posted of string
      (** This node's log already holds the same announcement. *)
  | Held of string
      (** Not written: the one line saying why, and what to run again. *)
  | No_node of string  (** No node runs here: the line that posts it. *)

type error =
  | Waiting of string  (** A signer has not signed; nothing was published. *)
  | Failed of string

let error_to_string = function Waiting e | Failed e -> e

type env = {
  gh : string list -> (string, string) result;
  repo : string;
  signers : Release.signer list;
  channel :
    message:string -> (string -> (unit, string) result) -> (bool, string) result;
      (** Commit what the function writes into a checkout of the channel branch,
          as one commit titled [message]; true when it changed anything. *)
  announce :
    Release.relay_manifest Release.signed -> (announced, string) result;
  say : string -> unit;
}

let tag_of version = Sign_next.relay_tag_prefix ^ Version.to_string version
let failed r = Result.map_error (fun e -> Failed e) r

(* Step 1: the draft's manifest and the signature of every signer, checked; the signatures kept
   are one valid signature per signer, as manifest.sig.json carries them. *)
let verified env ~version =
  let tag = tag_of version in
  let* listed = failed (env.gh [ "api"; Sign_next.releases_path env.repo ]) in
  let* releases = failed (Sign_next.relay_releases_of_string listed) in
  let* release =
    match List.find_opt (fun (r : Sign_next.draft) -> r.tag = tag) releases with
    | Some r -> Ok r
    | None -> Error (Failed ("the release " ^ tag ^ " is gone"))
  in
  let* bytes, doc =
    failed (Sign_next.relay_manifest_of ~gh:env.gh ~repo:env.repo release)
  in
  let* () =
    if Version.equal doc.relay_version version then Ok ()
    else
      Error
        (Failed
           (Printf.sprintf
              "%s's manifest names version %s; nothing was published" tag
              (Version.to_string doc.relay_version)))
  in
  let* sigs =
    failed
      (Release.all
         (fun (a : Sign_next.asset) ->
           let* b = Sign_next.download_asset ~gh:env.gh ~repo:env.repo a in
           Result.map_error
             (fun e -> a.name ^ ": " ^ e)
             (Release.signatures_of_string b))
         (List.filter
            (fun (a : Sign_next.asset) -> Sign_next.is_signature_asset a.name)
            release.assets))
  in
  let valid =
    Release.valid_signers ~domain:Release.relay_release_domain bytes
      (List.concat sigs)
  in
  let kept =
    List.filter_map
      (fun (s : Release.signer) ->
        if List.mem s.key valid then
          List.find_opt
            (fun (g : Release.signature) -> g.by = s.key)
            (List.concat sigs)
        else None)
      env.signers
  in
  let signed = { Release.bytes; doc; signatures = kept } in
  match Policy.check_relay { signers = env.signers; revoked = [] } signed with
  | Ok () -> Ok (release, signed)
  | Error (Policy.Missing_signatures names) ->
      Error
        (Waiting
           (Printf.sprintf
              "%s waits for the signature of %s; nothing was published" tag
              (String.concat ", " names)))
  | Error r ->
      Error
        (Failed
           (Printf.sprintf "%s does not count: %s; nothing was published" tag
              (Policy.refusal_to_string r)))

(* relay/ on the channel (docs/releases.md, The channel): relay/<version>/manifest.json, its exact
   bytes, relay/<version>/manifest.sig.json, every signer's signature, and relay/index.json, the
   node index's shape with format digestif-relay-feed-v0, listing every published relay version in
   version order and the channel's revocations. The channel is the record a person reads; nodes act
   on the announcement and never read relay/. *)
let relay_feed_format = "digestif-relay-feed-v0"
let read path = In_channel.with_open_bin path In_channel.input_all

let write path bytes =
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc bytes)

let rec mkdir_p d =
  if not (Sys.file_exists d) then (
    mkdir_p (Filename.dirname d);
    Sys.mkdir d 0o755)

let entry v =
  `Assoc
    [
      ("version", `String v);
      ("manifest", `String (v ^ "/manifest.json"));
      ("signatures", `String (v ^ "/manifest.sig.json"));
    ]

(* The channel's revocations, named from relay/ as candidate/index.json names them. *)
let revocations ~dir =
  let index = Filename.concat dir "index.json" in
  if not (Sys.file_exists index) then Ok []
  else
    let* json = Release.parse_json "index.json" (read index) in
    match Release.field "revocations" json with
    | None | Some `Null -> Ok []
    | Some (`List l) ->
        Release.all
          (fun r ->
            let* d = Release.string_field "document" r in
            let* s = Release.string_field "signatures" r in
            Ok
              (`Assoc
                 [
                   ("document", `String ("../" ^ d));
                   ("signatures", `String ("../" ^ s));
                 ]))
          l
    | Some _ -> Error "index.json: revocations is not a list"

let listed_versions ~relay_dir =
  let index = Filename.concat relay_dir "index.json" in
  if not (Sys.file_exists index) then Ok []
  else
    let* json = Release.parse_json "relay/index.json" (read index) in
    let* l = Release.list_field "releases" json in
    Release.all
      (fun r ->
        let* v = Release.string_field "version" r in
        Version.of_string v)
      l

let write_channel ~dir (signed : Release.relay_manifest Release.signed) =
  let v = Version.to_string signed.doc.relay_version in
  let relay_dir = Filename.concat dir "relay" in
  let vdir = Filename.concat relay_dir v in
  let manifest = Filename.concat vdir "manifest.json" in
  let* () =
    if Sys.file_exists manifest && read manifest <> signed.bytes then
      Error
        (Printf.sprintf
           "the channel already holds a different manifest for relay %s; \
            nothing was written"
           v)
    else Ok ()
  in
  let* listed = listed_versions ~relay_dir in
  let* revocations = revocations ~dir in
  mkdir_p vdir;
  write manifest signed.bytes;
  write
    (Filename.concat vdir "manifest.sig.json")
    (Release.signatures_to_string signed.signatures);
  let versions =
    List.sort_uniq Version.compare (signed.doc.relay_version :: listed)
  in
  write
    (Filename.concat relay_dir "index.json")
    (Yojson.Safe.pretty_to_string
       (`Assoc
          [
            ("format", `String relay_feed_format);
            ( "releases",
              `List (List.map (fun v -> entry (Version.to_string v)) versions)
            );
            ("revocations", `List revocations);
          ])
    ^ "\n");
  Ok ()

(* Step 3's rule. A relay deployed before relay releases does not know the relay_release kind and
   answers its append 422 malformed, which a node's sync reads as a permanent refusal: it would
   drop the announcement from its log, or, once another relay holds it, push it again on every
   sync. Such a relay reports no relay_version on GET /v0/circle, the field the relay release build
   stamps, so the announcement is written only when every relay this node syncs with reports one.
   Otherwise nothing is written and the signer is told in one line why and what to run again:
   that is the first relay release, announced again once both relays run it (docs/releases.md,
   Moving the two existing relays, step 6). A relay that could not be read is held the same way,
   since whether it knows the kind is unknown. *)
let held_line ~version (reads : Sign_next.relay_read list) =
  let v = Version.to_string version in
  let again =
    Printf.sprintf "run ci/release.sh relay-publish --version %s again" v
  in
  let names l = String.concat " and " l in
  match
    ( List.filter_map
        (fun (url, r) -> match r with Ok None -> Some url | _ -> None)
        reads,
      List.filter_map
        (fun (url, r) ->
          match r with Error e -> Some (url ^ " (" ^ e ^ ")") | _ -> None)
        reads )
  with
  | [], [] -> None
  | (_ :: rest as behind), _ ->
      Some
        (Printf.sprintf
           "Not announced: %s %s not know relay_release yet (no relay_version \
            on GET /v0/circle), so %s would refuse the append; once %s relay \
            %s by hand, %s (docs/releases.md, Moving the two existing relays, \
            step 6)."
           (names behind)
           (if rest = [] then "does" else "do")
           (if rest = [] then "it" else "they")
           (if rest = [] then "it runs" else "each runs")
           v again)
  | [], unread ->
      Some
        (Printf.sprintf
           "Not announced: %s could not be read, so whether %s relay_release \
            is unknown; %s once %s."
           (names unread)
           (if List.length unread = 1 then "it knows" else "they know")
           again
           (if List.length unread = 1 then "it answers" else "they answer"))

let relay_version_of_circle (json : Yojson.Safe.t) =
  match Release.field "relay_version" json with
  | Some (`String s) when String.trim s <> "" -> Some s
  | _ -> None

(* Every relay this node syncs with, read now with its device key. *)
let read_relays ~transport (node : Node.t) : Sign_next.relay_read list =
  let relays = Log.relays node.log in
  match Node.device_key node with
  | Error e -> List.map (fun (r : Log.relay_row) -> (r.url, Error e)) relays
  | Ok key ->
      List.map
        (fun (r : Log.relay_row) ->
          ( r.url,
            match Relay_client.circle transport ~base:r.url ~key with
            | Ok json -> Ok (relay_version_of_circle json)
            | Error e -> Error (Relay_client.error_to_string e) ))
        relays

let document_of_body (body : Yojson.Safe.t option) =
  match body with
  | Some json -> (
      match Release.field "document" json with
      | Some (`String d) -> Some d
      | _ -> None)
  | None -> None

(* The line that posts [body] from a machine running a node. *)
let post_line body =
  Printf.sprintf "printf '%%s' '%s' | digestif post --kind %s --body -"
    (Yojson.Safe.to_string body)
    Circle_relay_release.kind

(* Step 3 through [node]: the announcement already in its log, or held, or written. *)
let announce ~reads (node : Node.t)
    (signed : Release.relay_manifest Release.signed) =
  let body = Circle_relay_release.to_body signed in
  let document = document_of_body (Some body) in
  match
    List.find_opt
      (fun (row : Log.row) -> document_of_body row.signed.body = document)
      (Log.of_kind node.log Circle_relay_release.kind)
  with
  | Some row -> Ok (Already_posted row.hash)
  | None -> (
      match held_line ~version:signed.doc.relay_version (reads ()) with
      | Some line -> Ok (Held line)
      | None ->
          let* hash, _ = Node.write node ~kind:Circle_relay_release.kind body in
          Ok (Posted hash))

let announced_line = function
  | Posted hash ->
      Printf.sprintf
        "Announced on the circle as %s; this node's next sync carries it." hash
  | Already_posted hash ->
      Printf.sprintf "Already announced on the circle as %s." hash
  | Held line -> line
  | No_node line ->
      "No node runs here; announce it from a machine running one:\n  " ^ line

let run env ~version =
  let tag = tag_of version in
  let* release, signed = verified env ~version in
  env.say
    (Printf.sprintf "%s: signed by %s." tag
       (String.concat ", "
          (List.map (fun (s : Release.signer) -> s.name) env.signers)));
  let* () =
    if release.draft then (
      let* _ =
        failed
          (env.gh
             [
               "release";
               "edit";
               tag;
               "--repo";
               env.repo;
               "--draft=false";
               "--latest=false";
             ])
      in
      env.say
        (Printf.sprintf "Published the GitHub release %s, not as Latest." tag);
      Ok ())
    else (
      env.say (Printf.sprintf "The GitHub release %s is already published." tag);
      Ok ())
  in
  let* changed =
    failed
      (env.channel
         ~message:
           (Printf.sprintf "Relay release %s" (Version.to_string version))
         (fun dir -> write_channel ~dir signed))
  in
  env.say
    (if changed then
       Printf.sprintf "Wrote relay/%s/ and relay/index.json on the channel."
         (Version.to_string version)
     else
       Printf.sprintf "The channel already holds relay/%s/."
         (Version.to_string version));
  let* announced = failed (env.announce signed) in
  env.say (announced_line announced);
  Ok announced
