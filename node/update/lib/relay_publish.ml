(* Publishing a relay release (docs/releases.md, Publishing a relay release): `ci/release.sh
   relay-publish --version X`, which runs `digestif-update relay-publish`, and `sign --next` itself
   when the signature it just uploaded completes the signer set. Three steps, each safe to run
   again:

   1. Download the draft's manifest and every signature and check them as a node does
      (Policy.check_relay against the trust the channel leaves: the build's signer set advanced by
      the channel's signers/ and every revocation it lists, the set sign --next signs under), so
      nothing is published that a node would not count.
   2. Upload the combined manifest.sig.json, every signer's signature that verified, to the release
      beside the per-signer files, and publish the GitHub release, never as Latest. The release is
      the relay version's one record: the break-glass deploy reads its manifest and
      manifest.sig.json from there, and nothing is written to the channel.
   3. Write the announcement, a relay_release circle message, through this machine's node for its
      next sync to carry, exactly as a recall posts a release_recall; on a machine running no node,
      print the line that posts it from one that does.

   Everything on GitHub goes through the signer's own gh login, passed in, so the flow is tested
   without the network. *)

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
  trust : unit -> (Policy.trust, string) result;
      (** The trust a node reading the channel holds (Signers_channel.trust):
          the set every signature is checked against, and its revocations. *)
  announce :
    Release.relay_manifest Release.signed -> (announced, string) result;
  say : string -> unit;
  timer : Timing.t;
      (** Where each step's time goes (sign --next's timing log), or
          [Timing.none]. *)
}

let tag_of version = Sign_next.relay_tag_prefix ^ Version.to_string version
let failed r = Result.map_error (fun e -> Failed e) r

(* Each step of the run timed into [env.timer] as "settle <step>": sign --next times the whole run
   as its "settle" step, and these lines say which part of it the time went to. *)
let time env step f = Timing.time env.timer ("settle " ^ step) f

(* The draft named [tag] in a fresh read of the releases listing: its assets as they are now, the
   signature just uploaded included. *)
let listed_draft env ~tag =
  let* listed = failed (env.gh [ "api"; Sign_next.releases_path env.repo ]) in
  let* releases = failed (Sign_next.relay_releases_of_string listed) in
  match List.find_opt (fun (r : Sign_next.draft) -> r.tag = tag) releases with
  | Some r -> Ok r
  | None -> Error (Failed ("the release " ^ tag ^ " is gone"))

(* The draft's manifest.json: [known], the bytes the caller already downloaded from it, when the
   draft's manifest.json is still those bytes by the digest GitHub computed, else downloaded now. *)
let manifest_bytes env ~known (release : Sign_next.draft) =
  match (known, Sign_next.manifest_asset release) with
  | Some b, Ok { Sign_next.digest = Some d; _ } when d = Keys.hash_of_bytes b ->
      Ok b
  | _ -> Sign_next.fetch_manifest ~gh:env.gh ~repo:env.repo release

(* Every signature asset on the draft, downloaded at once. *)
let signature_assets env (release : Sign_next.draft) =
  let assets =
    List.filter
      (fun (a : Sign_next.asset) -> Sign_next.is_signature_asset a.name)
      release.assets
  in
  Release.all Fun.id
    (Parallel.map
       (fun (a : Sign_next.asset) ->
         let* b = Sign_next.download_asset ~gh:env.gh ~repo:env.repo a in
         Result.map_error
           (fun e -> a.name ^ ": " ^ e)
           (Release.signatures_of_string b))
       assets)

(* Step 1: the draft's manifest and the signature of every signer, checked; the signatures kept
   are, per signer, the one that verified, as manifest.sig.json carries them. The listing and the
   channel's trust are read at once, then the manifest and the signatures at once. *)
let verified env ?manifest ~version () =
  let tag = tag_of version in
  let release, trust =
    Parallel.both
      (fun () -> time env "listing" (fun () -> listed_draft env ~tag))
      (fun () -> time env "trust" (fun () -> failed (env.trust ())))
  in
  let* release = release in
  let* trust = trust in
  let bytes, sigs =
    Parallel.both
      (fun () ->
        time env "manifest" (fun () ->
            failed (manifest_bytes env ~known:manifest release)))
      (fun () ->
        time env "signatures" (fun () -> failed (signature_assets env release)))
  in
  let* bytes = bytes in
  let* bytes, doc = failed (Sign_next.relay_manifest_of release bytes) in
  let* () =
    if Version.equal doc.relay_version version then Ok ()
    else
      Error
        (Failed
           (Printf.sprintf
              "%s's manifest names version %s; nothing was published" tag
              (Version.to_string doc.relay_version)))
  in
  let* sigs = sigs in
  let kept =
    Release.verified_signatures ~domain:Release.relay_release_domain
      ~wanted:(fun k ->
        List.exists (fun (s : Release.signer) -> s.key = k) trust.signers)
      bytes (List.concat sigs)
  in
  let signed = { Release.bytes; doc; signatures = kept } in
  match Policy.check_relay trust signed with
  | Ok () -> Ok (release, signed, trust)
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

(* Step 2's file: the signatures kept, as manifest.sig.json, uploaded to the release so a reader
   of one signatures file (the break-glass deploy) finds every signer's in it. *)
let upload_signatures env ~tag (signed : Release.relay_manifest Release.signed) =
  let dir = Filename.temp_dir "digestif-relay-publish" "" in
  let path = Filename.concat dir "manifest.sig.json" in
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with Sys_error _ -> ());
      try Sys.rmdir dir with Sys_error _ -> ())
    (fun () ->
      Out_channel.with_open_bin path (fun oc ->
          Out_channel.output_string oc
            (Release.signatures_to_string signed.signatures));
      Result.map ignore
        (env.gh [ "release"; "upload"; tag; path; "--repo"; env.repo; "--clobber" ]))

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

(* [manifest]: the draft's manifest.json as the caller already downloaded it (sign --next), used
   when the draft still holds those bytes. *)
let run ?manifest env ~version =
  let tag = tag_of version in
  let* release, signed, trust = verified env ?manifest ~version () in
  env.say
    (Printf.sprintf "%s: signed by %s." tag
       (String.concat ", "
          (List.map (fun (s : Release.signer) -> s.name) trust.signers)));
  let* () =
    time env "upload" @@ fun () -> failed (upload_signatures env ~tag signed)
  in
  env.say (Printf.sprintf "Uploaded manifest.sig.json to %s." tag);
  let* () =
    if release.draft then (
      let* _ =
        time env "release-edit" @@ fun () ->
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
  let* announced =
    time env "announce" (fun () -> failed (env.announce signed))
  in
  env.say (announced_line announced);
  Ok announced
