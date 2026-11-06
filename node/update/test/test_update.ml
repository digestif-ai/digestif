open Digestif_update
open Digestif_core

(* Fixed seeds, so every run signs with the same keys. *)
let secret n = Crypto.signing_key_of_seed_exn (String.make 32 (Char.chr n))
let mike = secret 1
let roman = secret 2
let carol = secret 3
let roman2 = secret 4
let mallory = secret 5
let signer name s : Release.signer = { name; key = Keys.public s }
let founders = [ signer "Mike" mike; signer "Roman" roman ]
let trust signers : Policy.trust = { signers; revoked = [] }
let v s = match Version.of_string s with Ok v -> v | Error e -> failwith e
let platform = "darwin-arm64"

(* A release archive as a signer bundles it: bin/digestif, behaviors/ and runtime/. The fake binary
   answers `self-test` the way the real one does, except 0.3.0, whose self-test fails, and 0.5.0
   carries no runtime. The fake Node.js answers --version as Node.js 24. *)
let script version =
  Printf.sprintf
    "#!/bin/sh\n\
     case \"$1\" in\n\
     self-test)\n\
    \  if [ %S = 0.3.0 ]; then echo 'the store would not open' >&2; exit 3; fi\n\
    \  echo 'version %s'; exit 0 ;;\n\
     esac\n\
     exit 0\n"
    version version

let archives = Hashtbl.create 8

let binary_bytes version =
  match Hashtbl.find_opt archives version with
  | Some b -> b
  | None ->
      let root = Filename.temp_dir "digestif-archive" "" in
      let put rel contents perm =
        let path = Filename.concat root rel in
        let rec mk d =
          if not (Sys.file_exists d) then (
            mk (Filename.dirname d);
            Unix.mkdir d 0o755)
        in
        mk (Filename.dirname path);
        Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_trunc ]
          perm path (fun oc -> Out_channel.output_string oc contents)
      in
      put "bin/digestif" (script version) 0o755;
      put "behaviors/bin/nightly-hook" "#!/bin/sh\nexit 0\n" 0o755;
      put "behaviors/package.json" {|{ "engines": { "node": ">=24" } }|} 0o644;
      let runtime = version <> "0.5.0" in
      if runtime then put "runtime/bin/node" "#!/bin/sh\necho v24.1.0\n" 0o755;
      let out = root ^ ".tar.gz" in
      let code =
        Sys.command
          (Printf.sprintf "tar -czf %s -C %s bin behaviors%s"
             (Filename.quote out) (Filename.quote root)
             (if runtime then " runtime" else ""))
      in
      if code <> 0 then failwith "tar failed";
      let b = In_channel.with_open_bin out In_channel.input_all in
      Hashtbl.replace archives version b;
      b

let manifest_json ?signers ?(artifact = None) version =
  let bytes = binary_bytes version in
  let a =
    match artifact with
    | Some a -> a
    | None ->
        `Assoc
          [
            ("platform", `String platform);
            ("url", `String ("artifacts/" ^ version));
            ("sha256", `String (Keys.hash_of_bytes bytes));
            ("size", `Int (String.length bytes));
          ]
  in
  Yojson.Safe.pretty_to_string
    (`Assoc
       ([
          ("format", `String "digestif-release-v1");
          ("version", `String version);
          ("published_at", `String "2026-10-29T00:00:00.000Z");
          ("artifacts", `List [ a ]);
        ]
       @
       match signers with
       | None -> []
       | Some l -> [ ("signers", `List (List.map Release.signer_to_json l)) ]))

let sign_all ~domain secrets bytes =
  List.fold_left
    (fun sigs s -> Release.add_signature ~domain ~secret:s bytes sigs)
    [] secrets

let release ?signers ~by version : Release.manifest Release.signed =
  let bytes = manifest_json ?signers version in
  let doc =
    match Release.manifest_of_string bytes with
    | Ok d -> d
    | Error e -> failwith e
  in
  { bytes; doc; signatures = sign_all ~domain:Release.release_domain by bytes }

let revocation ~by target : Release.revocation Release.signed =
  let bytes =
    Yojson.Safe.to_string
      (`Assoc
         [
           ("format", `String "digestif-revocation-v0");
           ("key", `String (Keys.public target));
           ("reason", `String "leaked");
           ("revoked_at", `String "2026-10-29T00:00:00.000Z");
         ])
  in
  let doc =
    match Release.revocation_of_string bytes with
    | Ok d -> d
    | Error e -> failwith e
  in
  {
    bytes;
    doc;
    signatures = sign_all ~domain:Release.revocation_domain by bytes;
  }

let plan ?(installed = "0.1.0") ?pin ?(revocations = []) t releases =
  Policy.plan ~installed:(v installed) ~pin:(Option.map v pin) ~platform t
    ~revocations releases

let installs (p : Policy.plan) =
  Option.map
    (fun (r : Release.manifest Release.signed) ->
      Version.to_string r.doc.version)
    p.install

let check_installs msg want p =
  Alcotest.(check (option string)) msg want (installs p)

let reasons (p : Policy.plan) =
  List.map (fun (s : Policy.skipped) -> s.reason) p.skipped

let contains ~sub s =
  let n = String.length sub in
  let rec go i =
    i + n <= String.length s && (String.sub s i n = sub || go (i + 1))
  in
  go 0

let check_refused msg sub p =
  Alcotest.(check bool)
    (msg ^ ": " ^ String.concat "; " (reasons p))
    true
    (List.exists (contains ~sub) (reasons p))

(* Encoding *)

let test_b64url () =
  for n = 0 to 40 do
    let s = String.init n (fun i -> Char.chr (i * 37 land 255)) in
    Alcotest.(check (result string string))
      "roundtrip" (Ok s)
      (B64url.decode (B64url.encode s))
  done;
  Alcotest.(check bool)
    "non-canonical trailing bits refused" true
    (Result.is_error (B64url.decode "AB"))

let test_version () =
  Alcotest.(check bool)
    "orders numerically" true
    (Version.compare (v "0.10.0") (v "0.9.9") > 0);
  List.iter
    (fun s ->
      Alcotest.(check bool) s true (Result.is_error (Version.of_string s)))
    [ "1.2"; "01.2.3"; "1.2.3-rc1"; "v1.2.3"; "" ]

(* Both signers *)

let test_no_signers () =
  let p = plan (trust []) [ release ~by:[ mike; roman ] "0.2.0" ] in
  check_installs "nothing without a trust root" None p;
  check_refused "says why" "no release signers" p

let test_one_configured_signer () =
  let p =
    plan (trust [ signer "Mike" mike ]) [ release ~by:[ mike ] "0.2.0" ]
  in
  check_installs "one person cannot release" None p;
  check_refused "says why" "only Mike is configured" p

let test_both_signed () =
  check_installs "installs" (Some "0.2.0")
    (plan (trust founders) [ release ~by:[ mike; roman ] "0.2.0" ])

let test_one_signer () =
  let p = plan (trust founders) [ release ~by:[ mike ] "0.2.0" ] in
  check_installs "refused" None p;
  check_refused "names the missing signer" "not signed by Roman" p

let test_outsider_does_not_count () =
  check_installs "a third key is no substitute" None
    (plan (trust founders) [ release ~by:[ mike; mallory ] "0.2.0" ])

let test_signature_over_other_bytes () =
  let good = release ~by:[ mike; roman ] "0.2.0" in
  let tampered = { good with bytes = good.bytes ^ " " } in
  check_installs "a changed byte breaks the signatures" None
    (plan (trust founders) [ tampered ])

let test_newest () =
  check_installs "newest both-signed release" (Some "0.3.0")
    (plan (trust founders)
       [
         release ~by:[ mike; roman ] "0.3.0";
         release ~by:[ mike; roman ] "0.2.0";
         release ~by:[ mike ] "0.4.0";
       ])

let test_no_rollback () =
  check_installs "never older than installed" None
    (plan ~installed:"0.3.0" (trust founders)
       [ release ~by:[ mike; roman ] "0.2.0" ])

let test_duplicate_version () =
  let a = release ~by:[ mike; roman ] "0.2.0" in
  let bytes = a.bytes ^ "\n" in
  let b =
    {
      a with
      bytes;
      signatures = sign_all ~domain:Release.release_domain [ mike; roman ] bytes;
    }
  in
  let p = plan (trust founders) [ a; b ] in
  check_installs "two manifests for one version: neither" None p;
  check_refused "says why" "two manifests" p

(* Pinning *)

let test_pin () =
  let releases =
    [ release ~by:[ mike; roman ] "0.2.0"; release ~by:[ mike; roman ] "0.3.0" ]
  in
  check_installs "installs the pin, not the newest" (Some "0.2.0")
    (plan ~pin:"0.2.0" (trust founders) releases);
  check_installs "a pin at the installed version stays" None
    (plan ~installed:"0.2.0" ~pin:"0.2.0" (trust founders) releases)

let test_pin_unsigned () =
  check_installs "a pin does not waive a signature" None
    (plan ~pin:"0.2.0" (trust founders) [ release ~by:[ mike ] "0.2.0" ])

(* Changing the signer set *)

let new_set = [ signer "Mike" mike; signer "Carol" carol ]

let test_signer_change () =
  let p =
    plan (trust founders)
      [
        release ~signers:new_set ~by:[ mike; roman; carol ] "0.2.0";
        release ~by:[ mike; carol ] "0.3.0";
      ]
  in
  check_installs "the new set signs the next release" (Some "0.3.0") p;
  Alcotest.(check (list string))
    "trust moved" [ "Mike"; "Carol" ]
    (List.map (fun (s : Release.signer) -> s.name) p.trust.signers)

let test_old_set_after_change () =
  check_installs "the old set no longer suffices" (Some "0.2.0")
    (plan (trust founders)
       [
         release ~signers:new_set ~by:[ mike; roman; carol ] "0.2.0";
         release ~by:[ mike; roman ] "0.3.0";
       ])

let test_change_needs_both_current () =
  let p =
    plan (trust founders)
      [ release ~signers:new_set ~by:[ mike; carol ] "0.2.0" ]
  in
  check_installs "one current signer cannot change the set" None p;
  check_refused "names Roman" "not signed by Roman" p

let test_change_needs_new_keys () =
  let p =
    plan (trust founders)
      [ release ~signers:new_set ~by:[ mike; roman ] "0.2.0" ]
  in
  check_installs "new keys prove possession" None p;
  check_refused "names Carol" "Carol" p

let test_change_to_one_signer () =
  let p =
    plan (trust founders)
      [ release ~signers:[ signer "Mike" mike ] ~by:[ mike; roman ] "0.2.0" ]
  in
  check_installs "a set of one is refused" None p;
  check_refused "says why" "at least two" p

let test_change_past_pin () =
  let p =
    plan ~installed:"0.2.0" ~pin:"0.2.0" (trust founders)
      [ release ~signers:new_set ~by:[ mike; roman; carol ] "0.3.0" ]
  in
  check_installs "pinned: nothing installed" None p;
  Alcotest.(check int)
    "but the signer change is adopted" 2
    (List.length
       (List.filter
          (fun (s : Release.signer) -> s.name = "Carol" || s.name = "Mike")
          p.trust.signers))

(* Revocation *)

let test_revocation_halts () =
  let p =
    plan
      ~revocations:[ revocation ~by:[ mike ] roman ]
      (trust founders)
      [ release ~by:[ mike; roman ] "0.2.0" ]
  in
  check_installs "a revoked signer halts ordinary releases" None p;
  check_refused "says halted" "halted" p

let test_revocation_then_new_set () =
  let rotated = [ signer "Mike" mike; signer "Roman" roman2 ] in
  let p =
    plan
      ~revocations:[ revocation ~by:[ mike ] roman ]
      (trust founders)
      [
        release ~signers:rotated ~by:[ mike; roman; roman2 ] "0.2.0";
        release ~by:[ mike; roman2 ] "0.3.0";
      ]
  in
  check_installs "rotation clears the halt" (Some "0.3.0") p

let test_revoked_key_never_returns () =
  let p =
    plan
      ~revocations:[ revocation ~by:[ mike ] roman ]
      (trust founders)
      [
        release
          ~signers:[ signer "Mike" mike; signer "Roman" roman ]
          ~by:[ mike; roman ] "0.2.0";
      ]
  in
  check_installs "a set naming a revoked key is refused" None p;
  check_refused "says why" "revoked key" p

let test_outsider_revocation_ignored () =
  check_installs "a revocation only a current signer signed counts"
    (Some "0.2.0")
    (plan
       ~revocations:[ revocation ~by:[ mallory ] roman ]
       (trust founders)
       [ release ~by:[ mike; roman ] "0.2.0" ])

(* End to end through a channel on disk *)

let write path s =
  let rec mkdir_p d =
    if not (Sys.file_exists d) then (
      mkdir_p (Filename.dirname d);
      Unix.mkdir d 0o755)
  in
  mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc s)

let channel dir releases ~tamper =
  let entries =
    List.map
      (fun (r : Release.manifest Release.signed) ->
        let ver = Version.to_string r.doc.version in
        write
          (Filename.concat dir ("releases/" ^ ver ^ "/manifest.json"))
          r.bytes;
        write
          (Filename.concat dir ("releases/" ^ ver ^ "/manifest.sig.json"))
          (Release.signatures_to_string r.signatures);
        write
          (Filename.concat dir ("artifacts/" ^ ver))
          (binary_bytes ver ^ if tamper then "x" else "");
        `Assoc
          [
            ("version", `String ver);
            ("manifest", `String ("releases/" ^ ver ^ "/manifest.json"));
            ("signatures", `String ("releases/" ^ ver ^ "/manifest.sig.json"));
          ])
      releases
  in
  write
    (Filename.concat dir "index.json")
    (Yojson.Safe.to_string
       (`Assoc
          [
            ("format", `String "digestif-feed-v0");
            ("releases", `List entries);
            ("revocations", `List []);
          ]))

let temp_dir () =
  let d = Filename.temp_dir "digestif-update" "" in
  d

let loaded path =
  match State.load path with Ok s -> s | Error e -> Alcotest.fail e

let state_with_founders path =
  State.save path
    { (State.initial ()) with installed = v "0.1.0"; trust = trust founders }

(* A node already under its supervisor, running 0.1.0. *)
let supervised_node () =
  let node = temp_dir () in
  let root = Layout.release_dir node "0.1.0" in
  write (Layout.binary_in root) (script "0.1.0");
  Unix.chmod (Layout.binary_in root) 0o755;
  write (Layout.marker_in root)
    (Layout.marker_json ~version:(v "0.1.0") ~source:"test");
  Layout.point_current node "0.1.0";
  Layout.point_good node "0.1.0";
  state_with_founders (Schedule.state_path node);
  node

let node24 _ = Some 24

let update ?(node_major = node24) ?(fetch = Feed.default_fetch) ?(now = 1_000.)
    ~feed node =
  match
    Updater.run ~node_major ~fetch ~base:feed ~platform ~dir:node ~now ()
  with
  | Ok o -> o
  | Error e -> Alcotest.fail e

let current node = Option.value (Layout.current node) ~default:"-"

let test_end_to_end () =
  let dir = temp_dir () in
  let feed = Filename.concat dir "feed/" in
  channel feed [ release ~by:[ mike; roman ] "0.2.0" ] ~tamper:false;
  let node = supervised_node () in
  let o = update ~feed node in
  Alcotest.(check bool) "switched" true (o.step = Updater.Switched (v "0.2.0"));
  Alcotest.(check string) "current moved" "0.2.0" (current node);
  Alcotest.(check (option string))
    "good stays" (Some "0.1.0") (Layout.good node);
  Alcotest.(check bool)
    "the release carries its behaviors" true
    (Sys.file_exists
       (Filename.concat
          (Layout.behaviors_in (Layout.release_dir node "0.2.0"))
          "bin/nightly-hook"));
  Alcotest.(check bool)
    "a trial is recorded" true
    (Option.map (fun (t : Trial.t) -> t.previous) (Trial.load node)
    = Some "0.1.0");
  Alcotest.(check string)
    "installed waits for healthy" "0.1.0"
    (Version.to_string (loaded (Schedule.state_path node)).installed)

let test_unsupervised_stages_only () =
  let dir = temp_dir () in
  let feed = Filename.concat dir "feed/" in
  channel feed [ release ~by:[ mike; roman ] "0.2.0" ] ~tamper:false;
  let node = temp_dir () in
  state_with_founders (Schedule.state_path node);
  let o = update ~feed node in
  Alcotest.(check bool)
    "staged, not switched" true
    (match o.step with Updater.Staged (v', _) -> v' = v "0.2.0" | _ -> false);
  Alcotest.(check bool) "no current" true (Layout.current node = None);
  Alcotest.(check bool) "staged dir" true (Layout.staged node "0.2.0")

let test_tampered_artifact () =
  let dir = temp_dir () in
  let feed = Filename.concat dir "feed/" in
  channel feed [ release ~by:[ mike; roman ] "0.2.0" ] ~tamper:true;
  let node = supervised_node () in
  let o = update ~feed node in
  (match o.step with
  | Updater.Stage_failed (_, e, _) ->
      Alcotest.(check bool)
        ("refused: " ^ e) true
        (contains ~sub:"bytes" e || contains ~sub:"hashes" e)
  | _ -> Alcotest.fail "a tampered artifact staged");
  Alcotest.(check string) "current untouched" "0.1.0" (current node);
  Alcotest.(check bool) "nothing staged" false (Layout.staged node "0.2.0")

(* A download that breaks part way (here: the artifact fetch fails, and then arrives truncated)
   leaves current where it was, keeps the release pending with a backoff, and is tried again once
   the backoff passes. *)
let test_interrupted_download () =
  let dir = temp_dir () in
  let feed = Filename.concat dir "feed/" in
  channel feed [ release ~by:[ mike; roman ] "0.2.0" ] ~tamper:false;
  let node = supervised_node () in
  let broken = ref `Fail in
  let fetch target =
    if contains ~sub:"artifacts/" target then
      match !broken with
      | `Fail -> Error (target ^ ": curl exited 56")
      | `Short ->
          Result.map
            (fun b -> String.sub b 0 (String.length b / 2))
            (Feed.default_fetch target)
      | `Ok -> Feed.default_fetch target
    else Feed.default_fetch target
  in
  let o = update ~fetch ~now:1_000. ~feed node in
  let due =
    match o.step with
    | Updater.Stage_failed (_, e, due) ->
        Alcotest.(check bool)
          ("names the cause: " ^ e) true (contains ~sub:"curl" e);
        due
    | _ -> Alcotest.fail "a broken download did not fail the stage"
  in
  Alcotest.(check string) "current untouched" "0.1.0" (current node);
  Alcotest.(check bool) "no trial" true (Trial.load node = None);
  let s = loaded (Schedule.state_path node) in
  Alcotest.(check bool)
    "pending, attempt 1" true
    (match s.pending with Some p -> p.attempts = 1 | None -> false);
  broken := `Short;
  let o = update ~fetch ~now:(due -. 1.) ~feed node in
  Alcotest.(check bool)
    "waits out the backoff" true
    (o.step = Updater.Waiting (v "0.2.0"));
  let o = update ~fetch ~now:due ~feed node in
  Alcotest.(check bool)
    "a truncated download fails again" true
    (match o.step with Updater.Stage_failed _ -> true | _ -> false);
  Alcotest.(check bool)
    "attempt 2 backs off longer" true
    (match (loaded (Schedule.state_path node)).pending with
    | Some p -> p.attempts = 2 && p.due_at -. due > Updater.backoff 1
    | None -> false);
  Alcotest.(check string) "current still untouched" "0.1.0" (current node);
  broken := `Ok;
  let o = update ~fetch ~now:(due +. 86_400.) ~feed node in
  Alcotest.(check bool)
    "then it switches" true
    (o.step = Updater.Switched (v "0.2.0"));
  Alcotest.(check bool)
    "and the pending record clears" true
    ((loaded (Schedule.state_path node)).pending = None)

let test_failed_self_test_never_switches () =
  let dir = temp_dir () in
  let feed = Filename.concat dir "feed/" in
  channel feed [ release ~by:[ mike; roman ] "0.3.0" ] ~tamper:false;
  let node = supervised_node () in
  let o = update ~feed node in
  (match o.step with
  | Updater.Refused (_, why) ->
      Alcotest.(check bool)
        ("says why: " ^ why) true
        (contains ~sub:"self-test" why)
  | _ -> Alcotest.fail "a release whose self-test fails was not refused");
  Alcotest.(check string) "current untouched" "0.1.0" (current node);
  Alcotest.(check bool) "nothing staged" false (Layout.staged node "0.3.0");
  Alcotest.(check bool)
    "refused for good" true
    (State.is_refused (loaded (Schedule.state_path node)) (v "0.3.0"));
  let o = update ~now:200_000. ~feed node in
  Alcotest.(check bool) "never tried again" true (o.step = Updater.Nothing);
  check_refused "and says so" "this node refused it" o.plan

(* A release runs its behaviors with the Node.js it carries, by its path: staging asks that runtime
   and never a node on PATH, and a runtime that does not run is the release's own fault. *)
let test_runtime_is_the_releases () =
  let dir = temp_dir () in
  let feed = Filename.concat dir "feed/" in
  channel feed [ release ~by:[ mike; roman ] "0.2.0" ] ~tamper:false;
  let node = supervised_node () in
  let asked = ref [] in
  let o =
    update
      ~node_major:(fun exe ->
        asked := exe :: !asked;
        Some 24)
      ~feed node
  in
  Alcotest.(check bool)
    "it switches" true
    (o.step = Updater.Switched (v "0.2.0"));
  (match !asked with
  | [ exe ] ->
      Alcotest.(check bool)
        ("asked the release's own runtime: " ^ exe)
        true
        (Filename.is_relative exe = false
        && contains ~sub:"runtime/bin/node" exe)
  | l -> Alcotest.failf "asked %d runtimes" (List.length l));
  Alcotest.(check bool)
    "the runtime is in the release" true
    (Sys.file_exists (Layout.runtime_in (Layout.release_dir node "0.2.0")))

let test_runtime_that_does_not_run_is_refused () =
  let dir = temp_dir () in
  let feed = Filename.concat dir "feed/" in
  channel feed [ release ~by:[ mike; roman ] "0.2.0" ] ~tamper:false;
  let node = supervised_node () in
  let o = update ~node_major:(fun _ -> None) ~feed node in
  (match o.step with
  | Updater.Refused (_, why) ->
      Alcotest.(check bool)
        ("names Node.js: " ^ why) true
        (contains ~sub:"Node.js 24" why)
  | _ -> Alcotest.fail "a runtime that does not run was not refused");
  Alcotest.(check string) "current untouched" "0.1.0" (current node);
  Alcotest.(check bool)
    "refused for good" true
    (State.is_refused (loaded (Schedule.state_path node)) (v "0.2.0"))

let test_archive_without_runtime_is_refused () =
  let dir = temp_dir () in
  let feed = Filename.concat dir "feed/" in
  channel feed [ release ~by:[ mike; roman ] "0.5.0" ] ~tamper:false;
  let node = supervised_node () in
  let o = update ~feed node in
  (match o.step with
  | Updater.Refused (_, why) ->
      Alcotest.(check bool)
        ("names the runtime: " ^ why)
        true
        (contains ~sub:"runtime/bin/node" why)
  | _ -> Alcotest.fail "an archive without its Node.js was not refused");
  Alcotest.(check bool) "nothing staged" false (Layout.staged node "0.5.0")

(* A release staged from a checkout carries no runtime and runs the node on PATH, which installing
   Node.js fixes, so a missing one is retried rather than refused. *)
let test_local_release_uses_path_node () =
  let dir = temp_dir () in
  let node = Filename.concat dir "node" in
  let binary = Filename.concat dir "digestif" in
  Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_trunc ] 0o755 binary
    (fun oc -> Out_channel.output_string oc (script "0.2.0"));
  let behaviors = Filename.concat dir "behaviors" in
  Unix.mkdir behaviors 0o755;
  Out_channel.with_open_bin (Filename.concat behaviors "package.json")
    (fun oc ->
      Out_channel.output_string oc {|{ "engines": { "node": ">=24" } }|});
  write (Filename.concat behaviors "prompts/always-on.md") "rule";
  let asked = ref [] in
  (match
     Stage.local
       ~node_major:(fun exe ->
         asked := exe :: !asked;
         None)
       ~dir:node ~version:(v "0.2.0") ~binary ~behaviors:(Some behaviors) ()
   with
  | Error (Stage.Retry why) ->
      Alcotest.(check bool)
        ("names the PATH: " ^ why) true (contains ~sub:"PATH" why)
  | Error (Stage.Refuse why) -> Alcotest.failf "refused: %s" why
  | Ok _ -> Alcotest.fail "staged without Node.js");
  Alcotest.(check (list string)) "asked the node on PATH" [ "node" ] !asked

(* A release staged by hand and adopted by `service install` is good without a pass ever switching to
   it, and update.json still says the version the node started with. The updater plans from the
   good release's version, so it never offers the older release the channel lists (ISS-47825). *)
let test_installed_counts_good_release () =
  let dir = temp_dir () in
  let feed = Filename.concat dir "feed/" in
  channel feed [ release ~by:[ mike; roman ] "0.2.0" ] ~tamper:false;
  let node = temp_dir () in
  let root = Layout.release_dir node "local-abc" in
  write (Layout.binary_in root) (script "0.3.0");
  Unix.chmod (Layout.binary_in root) 0o755;
  write (Layout.marker_in root)
    (Layout.marker_json ~version:(v "0.3.0") ~source:"local");
  Layout.point_current node "local-abc";
  Layout.point_good node "local-abc";
  State.save (Schedule.state_path node)
    { (State.initial ()) with installed = v "0.0.0"; trust = trust founders };
  let o = update ~feed node in
  Alcotest.(check bool) "nothing older offered" true (o.step = Updater.Nothing);
  Alcotest.(check (option string)) "plans nothing" None (installs o.plan);
  Alcotest.(check string)
    "installed is the running release" "0.3.0"
    (Version.to_string (loaded (Schedule.state_path node)).installed);
  Alcotest.(check string) "current stays" "local-abc" (current node)

(* A recall that moved the node back lowers installed and good together, so the good release never
   lifts installed past what the move back saved. *)
let test_good_release_never_lowers_installed () =
  let node = supervised_node () in
  State.save (Schedule.state_path node)
    { (loaded (Schedule.state_path node)) with installed = v "0.4.0" };
  let state = Updater.with_good ~dir:node (loaded (Schedule.state_path node)) in
  Alcotest.(check string)
    "a newer installed stands" "0.4.0"
    (Version.to_string state.installed)

(* `service install` run from a copy of a staged release's binary adopts that release rather than
   staging the binary again as local-<hash> (ISS-47825). *)
let test_holding_finds_staged_release () =
  let node = temp_dir () in
  let stage ?(behaviors = true) name version =
    let root = Layout.release_dir node name in
    write (Layout.binary_in root) (script version);
    if behaviors then
      write
        (Filename.concat (Layout.behaviors_in root) "prompts/always-on.md")
        "rule";
    write (Layout.marker_in root)
      (Layout.marker_json ~version:(v version) ~source:"channel")
  in
  stage "local-0123456789ab" "0.2.0";
  stage "0.2.0" "0.2.0";
  stage "0.1.0" "0.1.0";
  stage ~behaviors:false "local-ba9876543210" "0.4.0";
  write
    (Filename.concat (Layout.releases_dir node) ".staging-0.3.0/bin/digestif")
    (script "0.3.0");
  let copy = Filename.concat (temp_dir ()) "digestif" in
  let holding version =
    write copy (script version);
    Stage.holding ~dir:node ~binary:copy
  in
  Alcotest.(check (option string))
    "the channel release, before a local one" (Some "0.2.0") (holding "0.2.0");
  Alcotest.(check (option string))
    "an older one" (Some "0.1.0") (holding "0.1.0");
  Alcotest.(check (option string))
    "never a half-staged one" None (holding "0.3.0");
  Alcotest.(check (option string))
    "never one without behaviors" None (holding "0.4.0");
  Alcotest.(check (option string))
    "no releases dir" None
    (Stage.holding ~dir:(temp_dir ()) ~binary:copy)

(* `service install` from a source build with no --behaviors stages the binary with the behaviors
   (and the runtime) of the release the node runs healthy, never as a release without them; with
   nothing to keep it refuses; and the same binary with other behaviors is a new release rather
   than the old one kept as it was (ISS-47847). *)
let local_binary version =
  let binary = Filename.concat (temp_dir ()) "digestif" in
  write binary (script version);
  Unix.chmod binary 0o755;
  binary

let stage_local ?behaviors node binary =
  Stage.local ~node_major:node24 ~dir:node ~version:(v "0.2.0") ~binary
    ~behaviors ()

let test_local_release_keeps_good_behaviors () =
  let node = supervised_node () in
  let good = Layout.release_dir node "0.1.0" in
  write
    (Filename.concat (Layout.behaviors_in good) "prompts/always-on.md")
    "rule";
  write
    (Filename.concat (Layout.behaviors_in good) "package.json")
    {|{ "engines": { "node": ">=24" } }|};
  write (Layout.runtime_in good) "node";
  let binary = local_binary "0.2.0" in
  match stage_local node binary with
  | Error (Stage.Retry e | Stage.Refuse e) -> Alcotest.failf "not staged: %s" e
  | Ok name ->
      let root = Layout.release_dir node name in
      Alcotest.(check bool)
        "carries the good release's prompts" true
        (Sys.file_exists
           (Filename.concat (Layout.behaviors_in root) "prompts/always-on.md"));
      Alcotest.(check bool)
        "and its runtime" true
        (Sys.file_exists (Layout.runtime_in root));
      Alcotest.(check bool) "has behaviors" true (Layout.has_behaviors root)

let test_local_release_without_behaviors_is_refused () =
  let node = supervised_node () in
  let binary = local_binary "0.2.0" in
  (match stage_local node binary with
  | Error (Stage.Refuse why) ->
      Alcotest.(check bool)
        ("names --behaviors: " ^ why)
        true
        (contains ~sub:"--behaviors" why)
  | Error (Stage.Retry e) -> Alcotest.failf "retried: %s" e
  | Ok name -> Alcotest.failf "staged %s without behaviors" name);
  let empty = Filename.concat (temp_dir ()) "behaviors" in
  Unix.mkdir empty 0o755;
  match stage_local ~behaviors:empty node binary with
  | Error (Stage.Refuse why) ->
      Alcotest.(check bool)
        ("names prompts/: " ^ why) true
        (contains ~sub:"prompts/" why)
  | Error (Stage.Retry e) -> Alcotest.failf "retried: %s" e
  | Ok name -> Alcotest.failf "staged %s from a directory without prompts" name

(* A binary built by a plain `dune build`, with no ui/build to embed, serves only the page saying how
   to build the UI. `service install` never stages it as a local release, and never adopts a staged
   release holding it (ISS-47891). *)
let without_web_ui version =
  script version
  ^ "# <p>This node was built without its web UI. Build it with \
     ci/build.slow.sh</p>\n"

let test_local_release_without_web_ui_is_refused () =
  let node = supervised_node () in
  let good = Layout.release_dir node "0.1.0" in
  write
    (Filename.concat (Layout.behaviors_in good) "prompts/always-on.md")
    "rule";
  let binary = local_binary "0.2.0" in
  write binary (without_web_ui "0.2.0");
  (match stage_local node binary with
  | Error (Stage.Refuse why) ->
      Alcotest.(check bool)
        ("names ci/build.slow.sh: " ^ why)
        true
        (contains ~sub:"ci/build.slow.sh" why)
  | Error (Stage.Retry e) -> Alcotest.failf "retried: %s" e
  | Ok name -> Alcotest.failf "staged %s without its web UI" name);
  let behaviors = Filename.concat (temp_dir ()) "behaviors" in
  write (Filename.concat behaviors "prompts/always-on.md") "rule";
  match stage_local ~behaviors node binary with
  | Error (Stage.Refuse _) -> ()
  | Error (Stage.Retry e) -> Alcotest.failf "retried: %s" e
  | Ok name -> Alcotest.failf "staged %s with --behaviors" name

let test_holding_skips_release_without_web_ui () =
  let node = temp_dir () in
  let root = Layout.release_dir node "local-0123456789ab" in
  write (Layout.binary_in root) (without_web_ui "0.2.0");
  write
    (Filename.concat (Layout.behaviors_in root) "prompts/always-on.md")
    "rule";
  write (Layout.marker_in root)
    (Layout.marker_json ~version:(v "0.2.0") ~source:"local");
  let copy = Filename.concat (temp_dir ()) "digestif" in
  write copy (without_web_ui "0.2.0");
  Alcotest.(check bool) "no web UI" false (Layout.has_web_ui root);
  Alcotest.(check (option string))
    "never one without its web UI" None
    (Stage.holding ~dir:node ~binary:copy)

(* The check reads the page web/embed embeds, and the binaries that link it are not that page: the
   sentence is joined at run time, so it is in no binary as one string. *)
let test_web_ui_marker_is_the_placeholder () =
  let embed = State.read_file "../../web/embed/embed.ml" in
  Alcotest.(check bool)
    "web/embed's page opens with the sentence" true
    (contains ~sub:(Layout.no_web_ui_marker ()) embed);
  Alcotest.(check bool)
    "a binary linking the check carries its web UI" true
    (Layout.binary_has_web_ui "../bin/main.exe");
  Alcotest.(check bool)
    "a binary that cannot be read does not" false
    (Layout.binary_has_web_ui (Filename.concat (temp_dir ()) "absent"))

let test_local_release_restages_other_behaviors () =
  let node = supervised_node () in
  let binary = local_binary "0.2.0" in
  let behaviors rule =
    let b = Filename.concat (temp_dir ()) "behaviors" in
    write (Filename.concat b "prompts/always-on.md") rule;
    b
  in
  let staged b =
    match stage_local ~behaviors:b node binary with
    | Ok name -> name
    | Error (Stage.Retry e | Stage.Refuse e) ->
        Alcotest.failf "not staged: %s" e
  in
  let first = staged (behaviors "one") in
  let again = staged (behaviors "one") in
  let other = staged (behaviors "two") in
  Alcotest.(check string) "the same build is staged once" first again;
  Alcotest.(check bool)
    "other behaviors are another release" true (first <> other);
  Alcotest.(check string)
    "holding the new behaviors" "two"
    (State.read_file
       (Filename.concat
          (Layout.behaviors_in (Layout.release_dir node other))
          "prompts/always-on.md"))

let test_state_roundtrip () =
  let s =
    {
      State.installed = v "1.2.3";
      trust = { signers = founders; revoked = [ Keys.public carol ] };
      pin = Some (v "1.2.3");
      refused = [ { refused_version = v "1.3.0"; why = "it crashed" } ];
      pending =
        Some
          {
            pending_version = v "1.4.0";
            cause = "curl";
            attempts = 2;
            due_at = 5.;
          };
      first_installed = [ (v "1.2.3", 7.) ];
      build_signers = Some [ Keys.public mike; Keys.public roman ];
    }
  in
  match State.of_string (State.to_string s) with
  | Ok s' ->
      Alcotest.(check string)
        "roundtrip" (State.to_string s) (State.to_string s')
  | Error e -> Alcotest.fail e

(* A node first written by a build that named one signer reaches the set its build names now. *)
let test_signer_set_reaches_build () =
  let path = Filename.concat (temp_dir ()) "update.json" in
  State.save path
    { (State.initial ()) with trust = trust [ signer "Mike" mike ] };
  (match State.load ~build:founders path with
  | Ok s ->
      Alcotest.(check int) "two signers" 2 (List.length s.trust.signers);
      let p = plan s.trust [ release ~by:[ mike; roman ] "0.2.0" ] in
      check_installs "and it installs a release both signed" (Some "0.2.0") p
  | Error e -> Alcotest.fail e);
  State.save path
    {
      (State.initial ()) with
      trust =
        { signers = [ signer "Mike" mike ]; revoked = [ Keys.public roman ] };
    };
  (match State.load ~build:founders path with
  | Ok s ->
      Alcotest.(check int)
        "never toward a revoked key" 1
        (List.length s.trust.signers)
  | Error e -> Alcotest.fail e);
  let three = founders @ [ signer "Carol" carol ] in
  State.save path { (State.initial ()) with trust = trust three };
  match State.load ~build:founders path with
  | Ok s ->
      Alcotest.(check int)
        "a larger stored set stays" 3
        (List.length s.trust.signers)
  | Error e -> Alcotest.fail e

(* A signed change that shrank the set holds against the build that named the larger set: that
   build was already seen, so loading under it never puts the removed signer back. *)
let test_signer_set_shrink_holds () =
  let path = Filename.concat (temp_dir ()) "update.json" in
  let three = founders @ [ signer "Carol" carol ] in
  State.save path { (State.initial ()) with trust = trust three };
  let s =
    match State.load ~build:three path with
    | Ok s -> s
    | Error e -> Alcotest.fail e
  in
  Alcotest.(check int) "the build's three" 3 (List.length s.trust.signers);
  State.save path { s with trust = trust founders };
  let reload label =
    match State.load ~build:three path with
    | Ok s ->
        Alcotest.(check int) label 2 (List.length s.trust.signers);
        State.save path s
    | Error e -> Alcotest.fail e
  in
  reload "the signed shrink holds";
  reload "and holds on every load";
  let four = three @ [ signer "Roman2" roman2 ] in
  match State.load ~build:four path with
  | Ok s ->
      Alcotest.(check int)
        "a build naming a set not seen before still extends it" 4
        (List.length s.trust.signers)
  | Error e -> Alcotest.fail e

(* A --key path that does not exist ends sign with one line naming it. *)
let test_sign_missing_key () =
  let dir = temp_dir () in
  let manifest = Filename.concat dir "manifest.json" in
  Out_channel.with_open_bin manifest (fun oc ->
      Out_channel.output_string oc "{}");
  let key = Filename.concat dir "absent.key"
  and err = Filename.concat dir "err" in
  let code =
    Sys.command
      (Printf.sprintf "../bin/main.exe sign --key %s %s 2>%s"
         (Filename.quote key) (Filename.quote manifest) (Filename.quote err))
  in
  let lines =
    In_channel.with_open_bin err In_channel.input_lines
    |> List.filter (fun l -> l <> "")
  in
  Alcotest.(check int) "exit 1" 1 code;
  match lines with
  | [ line ] ->
      Alcotest.(check bool)
        ("one line naming the file: " ^ line)
        true
        (String.starts_with ~prefix:("digestif-update: " ^ key) line)
  | _ -> Alcotest.failf "expected one line, got:\n%s" (String.concat "\n" lines)

(* verify: what `ci/release.sh candidate` runs on a version's manifest and the signature assets
   beside it. Each signer's signature arrives in its own file, as sign --next uploads it. *)
let run_verify ?(version = "0.2.0") ~by ?(extra = []) () =
  let dir = temp_dir () in
  let path name = Filename.concat dir name in
  let put name s =
    Out_channel.with_open_bin (path name) (fun oc ->
        Out_channel.output_string oc s)
  in
  put "signers.json"
    (Yojson.Safe.to_string
       (`Assoc
          [
            ("format", `String "digestif-signers-v0");
            ("signers", `List (List.map Release.signer_to_json founders));
          ]));
  let r = release ~by "0.2.0" in
  put "manifest.json" r.bytes;
  let sig_files =
    List.mapi
      (fun i s ->
        let name = Printf.sprintf "manifest.%d.sig.json" i in
        put name (Release.signatures_to_string [ s ]);
        path name)
      (r.signatures @ extra)
  in
  let code =
    Sys.command
      (Printf.sprintf
         "../bin/main.exe verify --signers %s --expect-version %s --out %s %s \
          %s >%s 2>%s"
         (Filename.quote (path "signers.json"))
         version
         (Filename.quote (path "out.sig.json"))
         (Filename.quote (path "manifest.json"))
         (String.concat " " (List.map Filename.quote sig_files))
         (Filename.quote (path "stdout"))
         (Filename.quote (path "stderr")))
  in
  let lines name =
    In_channel.with_open_bin (path name) In_channel.input_lines
    |> List.filter (fun l -> l <> "")
  in
  let out =
    if Sys.file_exists (path "out.sig.json") then
      match
        Release.signatures_of_string
          (In_channel.with_open_bin (path "out.sig.json") In_channel.input_all)
      with
      | Ok s -> Some (List.length s)
      | Error e -> failwith e
    else None
  in
  (code, lines "stdout", lines "stderr", out)

let test_verify_both () =
  let code, stdout, _, out = run_verify ~by:[ mike; roman ] () in
  Alcotest.(check int) "exit 0" 0 code;
  Alcotest.(check (list string))
    "each signer"
    [ "signed Mike"; "signed Roman" ]
    stdout;
  Alcotest.(check (option int)) "both signatures written" (Some 2) out

let test_verify_one_missing () =
  let code, stdout, stderr, out = run_verify ~by:[ mike ] () in
  Alcotest.(check int) "exit 1" 1 code;
  Alcotest.(check (list string))
    "each signer"
    [ "signed Mike"; "missing Roman" ]
    stdout;
  Alcotest.(check (list string))
    "the refusal"
    [ "digestif-update: not signed by Roman" ]
    stderr;
  Alcotest.(check (option int)) "nothing written" None out

(* A signature over other bytes, or by a key outside the set, is dropped rather than counted or
   carried into the channel. *)
let test_verify_drops_others () =
  let other = release ~by:[ roman ] "0.3.0" in
  let code, stdout, _, out =
    run_verify ~by:[ mike; mallory ] ~extra:other.signatures ()
  in
  Alcotest.(check int) "exit 1" 1 code;
  Alcotest.(check (list string))
    "each signer"
    [ "signed Mike"; "missing Roman" ]
    stdout;
  Alcotest.(check (option int)) "nothing written" None out;
  let code, _, _, out =
    run_verify ~by:[ mike; roman; mallory ] ~extra:other.signatures ()
  in
  Alcotest.(check int) "exit 0" 0 code;
  Alcotest.(check (option int)) "only the set's signatures" (Some 2) out

let test_verify_wrong_version () =
  let code, _, stderr, out =
    run_verify ~version:"0.2.1" ~by:[ mike; roman ] ()
  in
  Alcotest.(check int) "exit 1" 1 code;
  Alcotest.(check bool)
    ("names the version: " ^ String.concat "\n" stderr)
    true
    (List.exists
       (fun l -> String.ends_with ~suffix:"is version 0.2.0, not 0.2.1" l)
       stderr);
  Alcotest.(check (option int)) "nothing written" None out

(* Relay releases (docs/releases.md, Relay releases): the manifest, its domain line, and the fold of
   relay_release announcements against a node's own signer set. *)

let sha n = Keys.hash_of_bytes (string_of_int n)

let relay_manifest ?(compatible_with = "0.1.0") ?(notes = "")
    ?(migrations = [ "0001_init.sql"; "0002_mailer.sql" ]) version :
    Release.relay_manifest =
  {
    relay_version = v version;
    relay_published_at = "2026-11-12T18:00:00.000Z";
    relay_notes = notes;
    bundle =
      {
        bundle_url =
          Printf.sprintf
            "https://github.com/digestif-ai/digestif/releases/download/relay-v%s/digestif-relay-%s.tar.gz"
            version version;
        bundle_sha256 = sha 1;
        bundle_size = 812345;
      };
    migrations =
      List.mapi
        (fun i m -> { Release.migration = m; migration_sha256 = sha (i + 10) })
        migrations;
    compatible_with = v compatible_with;
  }

let relay_release ?compatible_with ?notes ~by version :
    Release.relay_manifest Release.signed =
  let doc = relay_manifest ?compatible_with ?notes version in
  let bytes = Release.relay_manifest_to_string doc in
  {
    bytes;
    doc;
    signatures = sign_all ~domain:Release.relay_release_domain by bytes;
  }

let test_relay_manifest_roundtrip () =
  let m = relay_manifest ~notes:"What changed." "0.3.0" in
  let bytes = Release.relay_manifest_to_string m in
  (match Release.relay_manifest_of_string bytes with
  | Ok back ->
      Alcotest.(check string)
        "written again, byte for byte" bytes
        (Release.relay_manifest_to_string back)
  | Error e -> Alcotest.fail e);
  Alcotest.(check bool)
    "read as a relay release" true
    (Release.document_kind bytes = Ok Release.Relay_release);
  Alcotest.(check bool)
    "never as a node release" true
    (Result.is_error (Release.manifest_of_string bytes))

let test_relay_manifest_refusals () =
  let refused what bytes =
    Alcotest.(check bool)
      what true
      (Result.is_error (Release.relay_manifest_of_string bytes))
  in
  let edit f =
    let json =
      Yojson.Safe.from_string
        (Release.relay_manifest_to_string (relay_manifest "0.3.0"))
    in
    match json with
    | `Assoc kv -> Yojson.Safe.to_string (`Assoc (f kv))
    | _ -> assert false
  in
  let set k value kv = (k, value) :: List.remove_assoc k kv in
  refused "another format" (edit (set "format" (`String "digestif-release-v1")));
  refused "compatible_with newer than the version"
    (edit (set "compatible_with" (`String "0.4.0")));
  refused "no compatible_with" (edit (List.remove_assoc "compatible_with"));
  refused "a bundle digest that is not sha256:<hex>"
    (edit
       (set "bundle"
          (`Assoc
             [
               ("url", `String "u"); ("sha256", `String "abc"); ("size", `Int 1);
             ])));
  let migration name =
    `Assoc [ ("name", `String name); ("sha256", `String (sha 2)) ]
  in
  refused "migrations out of order"
    (edit
       (set "migrations"
          (`List [ migration "0002_mailer.sql"; migration "0001_init.sql" ])));
  refused "a migration named twice"
    (edit
       (set "migrations"
          (`List [ migration "0001_init.sql"; migration "0001_init.sql" ])));
  refused "a migration name that is a path"
    (edit (set "migrations" (`List [ migration "../0001_init.sql" ])))

(* A relay signature is over its own domain line: it never verifies as a node release, a
   revocation or a recall, and theirs never as a relay release. *)
let test_relay_domain_line () =
  let r = relay_release ~by:[ mike; roman ] "0.3.0" in
  List.iter
    (fun (what, domain) ->
      Alcotest.(check int)
        ("a relay signature is no " ^ what)
        0
        (List.length (Release.valid_signers ~domain r.bytes r.signatures)))
    [
      ("node release", Release.release_domain);
      ("revocation", Release.revocation_domain);
      ("recall", Release.recall_domain);
    ];
  let as_node =
    {
      r with
      signatures =
        sign_all ~domain:Release.release_domain [ mike; roman ] r.bytes;
    }
  in
  Alcotest.(check bool)
    "a node release signature is no relay release" true
    (Result.is_error (Policy.check_relay (trust founders) as_node))

let announce (r : Release.relay_manifest Release.signed) hash :
    Circle_relay_release.announcement =
  (* Through text, as a relay stores and serves it. *)
  {
    hash;
    author = "ed25519:device";
    seq = 1;
    body =
      Yojson.Safe.from_string
        (Yojson.Safe.to_string (Circle_relay_release.to_body r));
  }

let newest (t : Circle_relay_release.t) =
  Option.map
    (fun (r : Release.relay_manifest Release.signed) ->
      Version.to_string r.doc.relay_version)
    t.newest

let counted (t : Circle_relay_release.t) =
  List.map
    (fun (r : Release.relay_manifest Release.signed) ->
      Version.to_string r.doc.relay_version)
    t.counted

let test_relay_fold_counts_every_signer () =
  let both = relay_release ~by:[ mike; roman ] "0.2.0" in
  let one = relay_release ~by:[ mike ] "0.3.0" in
  let t =
    Circle_relay_release.fold (trust founders)
      [ announce both "h1"; announce one "h2" ]
  in
  Alcotest.(check (option string))
    "the newest that counts" (Some "0.2.0") (newest t);
  match t.faults with
  | [ (Circle_relay_release.Not_counted { at; _ } as f) ] ->
      Alcotest.(check string) "the fault names it" "h2" at.hash;
      Alcotest.(check string)
        "and why" "h2 relay release 0.3.0 does not count: not signed by Roman"
        (Circle_relay_release.fault_detail f)
  | _ -> Alcotest.fail "one announcement short of a signer is one fault"

let test_relay_fold_halts_on_revoked_key () =
  let r = relay_release ~by:[ mike; roman ] "0.2.0" in
  let t =
    Circle_relay_release.fold
      { signers = founders; revoked = [ Keys.public roman ] }
      [ announce r "h1" ]
  in
  Alcotest.(check (option string)) "nothing counts" None (newest t);
  Alcotest.(check bool)
    "and says the set is halted" true
    (match t.faults with
    | [
     Circle_relay_release.Not_counted { refusal = Halted_by_revocation _; _ };
    ] ->
        true
    | _ -> false);
  let replaced = [ signer "Mike" mike; signer "Carol" carol ] in
  let r = relay_release ~by:[ mike; carol ] "0.2.1" in
  Alcotest.(check (option string))
    "a replaced signer set counts again" (Some "0.2.1")
    (newest
       (Circle_relay_release.fold
          { signers = replaced; revoked = [ Keys.public roman ] }
          [ announce r "h1" ]))

let test_relay_fold_orders_by_version () =
  let a = relay_release ~by:[ mike; roman ] "0.10.0" in
  let b = relay_release ~by:[ mike; roman ] "0.9.0" in
  let c = relay_release ~by:[ mike; roman ] "0.2.0" in
  let forward = [ announce c "h1"; announce b "h2"; announce a "h3" ] in
  let t = Circle_relay_release.fold (trust founders) forward in
  Alcotest.(check (option string)) "highest version" (Some "0.10.0") (newest t);
  Alcotest.(check (list string))
    "oldest first"
    [ "0.2.0"; "0.9.0"; "0.10.0" ]
    (counted t);
  Alcotest.(check (option string))
    "whatever order they arrive in" (Some "0.10.0")
    (newest (Circle_relay_release.fold (trust founders) (List.rev forward)));
  Alcotest.(check (option string))
    "a replayed old announcement changes nothing" (Some "0.10.0")
    (newest
       (Circle_relay_release.fold (trust founders)
          (forward @ [ announce c "h4" ])))

let test_relay_fold_conflict () =
  let one = relay_release ~notes:"one" ~by:[ mike; roman ] "0.3.0" in
  let two = relay_release ~notes:"two" ~by:[ mike; roman ] "0.3.0" in
  let older = relay_release ~by:[ mike; roman ] "0.2.0" in
  let t =
    Circle_relay_release.fold (trust founders)
      [ announce older "h0"; announce one "h1"; announce two "h2" ]
  in
  Alcotest.(check (list string)) "neither counts" [ "0.2.0" ] (counted t);
  (match t.faults with
  | [ Circle_relay_release.Conflicting { hashes; _ } ] ->
      Alcotest.(check (list string)) "both named" [ "h1"; "h2" ] hashes
  | _ -> Alcotest.fail "two documents under one version are one fault");
  let t =
    Circle_relay_release.fold (trust founders)
      [ announce one "h1"; announce one "h2" ]
  in
  Alcotest.(check (list string))
    "the same document twice is harmless" [ "0.3.0" ] (counted t);
  Alcotest.(check int) "and no fault" 0 (List.length t.faults)

let test_relay_fold_unreadable () =
  let bad : Circle_relay_release.announcement =
    {
      hash = "h1";
      author = "ed25519:device";
      seq = 1;
      body =
        `Assoc
          [
            ("document", `String (B64url.encode "{\"format\":\"nope\"}"));
            ("signatures", `List []);
          ];
    }
  in
  let t = Circle_relay_release.fold (trust founders) [ bad ] in
  Alcotest.(check (option string)) "nothing counts" None (newest t);
  Alcotest.(check bool)
    "a fault shown to the member" true
    (match t.faults with
    | [ Circle_relay_release.Unreadable { at; _ } ] -> at.hash = "h1"
    | _ -> false)

let write_file path s =
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc s)

(* relay-manifest reads every migration out of the bundle itself, then verify and sign take the
   manifest it writes as a relay release. *)
let test_relay_manifest_cli () =
  let dir = temp_dir () in
  let path name = Filename.concat dir name in
  let root = path "bundle" in
  List.iter
    (fun d -> Unix.mkdir d 0o755)
    [ root; Filename.concat root "migrations"; Filename.concat root "worker" ];
  write_file (Filename.concat root "worker/index.js") "export default {}\n";
  write_file
    (Filename.concat root "migrations/0001_init.sql")
    "CREATE TABLE a;\n";
  write_file
    (Filename.concat root "migrations/0002_mailer.sql")
    "CREATE TABLE b;\n";
  let archive = path "digestif-relay-0.3.0.tar.gz" in
  if
    Sys.command
      (Printf.sprintf "tar -czf %s -C %s worker migrations"
         (Filename.quote archive) (Filename.quote root))
    <> 0
  then Alcotest.fail "tar failed";
  let run args =
    Sys.command
      (Printf.sprintf "../bin/main.exe %s >%s 2>%s" args
         (Filename.quote (path "stdout"))
         (Filename.quote (path "stderr")))
  in
  let code =
    run
      (Printf.sprintf
         "relay-manifest 0.3.0 --bundle %s --url-base \
          https://example.test/relay-v0.3.0 --compatible-with 0.2.0 --notes \
          'Two tables.'"
         (Filename.quote archive))
  in
  Alcotest.(check int) "relay-manifest exits 0" 0 code;
  let bytes = In_channel.with_open_bin (path "stdout") In_channel.input_all in
  write_file (path "manifest.json") bytes;
  (match Release.relay_manifest_of_string bytes with
  | Error e -> Alcotest.fail e
  | Ok m ->
      Alcotest.(check (list string))
        "every migration in the bundle"
        [ "0001_init.sql"; "0002_mailer.sql" ]
        (List.map
           (fun (g : Release.relay_migration) -> g.migration)
           m.migrations);
      Alcotest.(check string)
        "each one's digest"
        (Keys.hash_of_bytes "CREATE TABLE b;\n")
        (List.nth m.migrations 1).migration_sha256;
      let b = In_channel.with_open_bin archive In_channel.input_all in
      Alcotest.(check string)
        "the bundle's digest" (Keys.hash_of_bytes b) m.bundle.bundle_sha256;
      Alcotest.(check string)
        "its url"
        "https://example.test/relay-v0.3.0/digestif-relay-0.3.0.tar.gz"
        m.bundle.bundle_url);
  write_file (path "signers.json")
    (Yojson.Safe.to_string
       (`Assoc
          [
            ("format", `String "digestif-signers-v0");
            ("signers", `List (List.map Release.signer_to_json founders));
          ]));
  write_file (path "mike.key") (Keys.encode_secret mike ^ "\n");
  write_file (path "roman.key") (Keys.encode_secret roman ^ "\n");
  let verify () =
    run
      (Printf.sprintf "verify --signers %s --expect-version 0.3.0 %s %s"
         (Filename.quote (path "signers.json"))
         (Filename.quote (path "manifest.json"))
         (Filename.quote (path "manifest.sig.json")))
  in
  let sign key =
    Alcotest.(check int)
      ("sign with " ^ key) 0
      (run
         (Printf.sprintf "sign --key %s %s"
            (Filename.quote (path key))
            (Filename.quote (path "manifest.json"))))
  in
  sign "mike.key";
  Alcotest.(check int) "one signer is not enough" 1 (verify ());
  Alcotest.(check (list string))
    "verify names who is missing"
    [ "signed Mike"; "missing Roman" ]
    (In_channel.with_open_bin (path "stdout") In_channel.input_lines);
  sign "roman.key";
  Alcotest.(check int) "both signers verify" 0 (verify ());
  match
    Release.signatures_of_string
      (In_channel.with_open_bin (path "manifest.sig.json") In_channel.input_all)
  with
  | Error e -> Alcotest.fail e
  | Ok signatures ->
      let doc =
        match Release.relay_manifest_of_string bytes with
        | Ok d -> d
        | Error e -> Alcotest.fail e
      in
      Alcotest.(check bool)
        "signed over the relay domain line" true
        (Policy.check_relay (trust founders) { bytes; doc; signatures } = Ok ())

let test_shipped_build_names_two () =
  Alcotest.(check bool)
    "node/update/release-signers.json names at least two signers" true
    (List.length (Trust_root.signers ()) >= 2)

(* The supervisor, with the world replaced: a fake child, a fake clock. *)

type sim = {
  mutable wall : float;
  mutable steps : int;
  mutable spawned : string list;
  mutable terminated : int;
}

let sim_ops ?(exit_at = None) ?(healthy_at = None) ?(sleep_at = None) node sim =
  let pid = 4242 in
  {
    Supervisor.spawn =
      (fun exe ->
        sim.spawned <- sim.spawned @ [ exe ];
        pid);
    poll =
      (fun _ ->
        match exit_at with
        | Some n when sim.steps >= n -> Some (Supervisor.Exited 1)
        | _ -> None);
    terminate = (fun _ -> sim.terminated <- sim.terminated + 1);
    sleep =
      (fun s ->
        sim.steps <- sim.steps + 1;
        sim.wall <-
          (sim.wall
          +.
          match sleep_at with
          | Some n when sim.steps = n -> 3. *. 3600.
          | _ -> s);
        match healthy_at with
        | Some (n, version) when sim.steps = n ->
            Health.write node { version; pid; at = sim.wall }
        | _ -> ());
    wall = (fun () -> sim.wall);
    stopping = (fun () -> false);
  }

let new_sim () = { wall = 0.; steps = 0; spawned = []; terminated = 0 }

(* A node that just switched to 0.2.0 and is on trial. *)
let switched_node () =
  let dir = temp_dir () in
  let feed = Filename.concat dir "feed/" in
  channel feed [ release ~by:[ mike; roman ] "0.2.0" ] ~tamper:false;
  let node = supervised_node () in
  ignore (update ~feed node);
  node

let trial_outcome ops node =
  match Trial.load node with
  | None -> Alcotest.fail "no trial"
  | Some t -> snd (Supervisor.trial ops node t)

let test_crash_on_start_rolls_back () =
  let node = switched_node () in
  let sim = new_sim () in
  let outcome = trial_outcome (sim_ops ~exit_at:(Some 2) node sim) node in
  Alcotest.(check bool)
    "rolled back" true
    (match outcome with Supervisor.Rolled_back _ -> true | _ -> false);
  Alcotest.(check string) "current moved back" "0.1.0" (current node);
  Alcotest.(check bool) "trial over" true (Trial.load node = None);
  let s = loaded (Schedule.state_path node) in
  Alcotest.(check bool) "refused for good" true (State.is_refused s (v "0.2.0"));
  Alcotest.(check string)
    "installed unchanged" "0.1.0"
    (Version.to_string s.installed);
  Alcotest.(check bool)
    "the digest hears of it" true
    (List.exists
       (contains ~sub:"Release 0.2.0 was rolled back to 0.1.0")
       (Report.load (Schedule.report_path node)).pending)

let test_healthy_is_kept () =
  let node = switched_node () in
  let sim = new_sim () in
  let outcome =
    trial_outcome (sim_ops ~healthy_at:(Some (3, "0.2.0")) node sim) node
  in
  Alcotest.(check bool) "healthy" true (outcome = Supervisor.Healthy (v "0.2.0"));
  Alcotest.(check (option string))
    "good moved" (Some "0.2.0") (Layout.good node);
  Alcotest.(check string)
    "installed only now" "0.2.0"
    (Version.to_string (loaded (Schedule.state_path node)).installed);
  Alcotest.(check (list string))
    "the digest hears of it"
    [ "Updated Digestif to 0.2.0." ]
    (Report.take (Schedule.report_path node))

let test_unhealthy_times_out () =
  let node = switched_node () in
  let sim = new_sim () in
  let outcome = trial_outcome (sim_ops node sim) node in
  Alcotest.(check bool)
    "rolled back" true
    (match outcome with Supervisor.Rolled_back _ -> true | _ -> false);
  Alcotest.(check int) "the child was stopped" 1 sim.terminated;
  Alcotest.(check bool)
    "after the bound of awake time" true
    (sim.wall >= Supervisor.health_bound);
  Alcotest.(check string) "current moved back" "0.1.0" (current node)

(* Three hours of sleep in the window count as one step: health that arrives a few awake minutes
   later still keeps the release. *)
let test_sleep_does_not_roll_back () =
  let node = switched_node () in
  let sim = new_sim () in
  let outcome =
    trial_outcome
      (sim_ops ~sleep_at:(Some 10) ~healthy_at:(Some (300, "0.2.0")) node sim)
      node
  in
  Alcotest.(check bool)
    "wall time passed the bound" true
    (sim.wall > Supervisor.health_bound);
  Alcotest.(check bool) "kept" true (outcome = Supervisor.Healthy (v "0.2.0"))

let test_trial_starts_are_bounded () =
  let node = switched_node () in
  (match Trial.load node with
  | Some t -> Trial.save node { t with starts = Supervisor.max_starts }
  | None -> Alcotest.fail "no trial");
  let sim = new_sim () in
  let outcome = trial_outcome (sim_ops node sim) node in
  Alcotest.(check bool)
    "rolled back without starting it again" true
    ((match outcome with Supervisor.Rolled_back _ -> true | _ -> false)
    && sim.spawned = [])

(* The supervisor's whole loop: the old release runs, switches and exits; the new one crashes; the
   old one runs again and its exit is the supervisor's. *)
let test_supervisor_loop () =
  let dir = temp_dir () in
  let feed = Filename.concat dir "feed/" in
  channel feed [ release ~by:[ mike; roman ] "0.2.0" ] ~tamper:false;
  let node = supervised_node () in
  let polls = ref 0 in
  let ops =
    {
      (sim_ops node (new_sim ())) with
      spawn =
        (fun _ ->
          if !polls = 0 then ignore (update ~feed node);
          1);
      poll =
        (fun _ ->
          incr polls;
          Some (Supervisor.Exited (if !polls = 1 then 0 else 7)));
    }
  in
  let status = Supervisor.run ops node in
  Alcotest.(check bool)
    "the last child's exit" true
    (status = Supervisor.Exited 7);
  Alcotest.(check string) "back on 0.1.0" "0.1.0" (current node)

let test_hook_follows_current () =
  let node = switched_node () in
  let checkout = "/Users/x/code/digestif/behaviors/bin/nightly-hook" in
  Alcotest.(check string)
    "a checkout's hook runs from current"
    (Filename.concat node "current/behaviors/bin/nightly-hook")
    (Layout.hook_path ~dir:node checkout);
  Alcotest.(check string)
    "another program runs as set" "/usr/local/bin/my-nightly"
    (Layout.hook_path ~dir:node "/usr/local/bin/my-nightly");
  Alcotest.(check string)
    "a file the release lacks runs as set" "/x/behaviors/bin/other"
    (Layout.hook_path ~dir:node "/x/behaviors/bin/other");
  let bare = temp_dir () in
  Alcotest.(check string)
    "no release, the checkout" checkout
    (Layout.hook_path ~dir:bare checkout)

let test_status_problems () =
  let node = supervised_node () in
  Alcotest.(check (list string)) "nothing wrong" [] (Status.problems ~dir:node);
  let path = Schedule.state_path node in
  let s = loaded path in
  State.save path
    {
      (State.refuse
         (State.refuse s (v "0.0.9") "old")
         (v "0.2.0") "it exited with status 1 before it reported healthy")
      with
      pending =
        Some
          {
            pending_version = v "0.3.0";
            cause = "curl exited 56";
            attempts = 1;
            due_at = 0.;
          };
    };
  match Status.problems ~dir:node with
  | [ pending; refused ] ->
      Alcotest.(check bool)
        pending true
        (contains ~sub:"Release 0.3.0 could not be staged: curl exited 56"
           pending);
      Alcotest.(check string)
        "a refusal newer than what runs"
        "Release 0.2.0 was refused: it exited with status 1 before it reported \
         healthy."
        refused
  | l -> Alcotest.fail (String.concat " | " l)

let test_awake_clock () =
  let t = Awake.step Awake.zero ~nominal:1. ~wall_delta:1.2 in
  let t = Awake.step t ~nominal:1. ~wall_delta:7200. in
  let t = Awake.step t ~nominal:1. ~wall_delta:(-50.) in
  Alcotest.(check (float 0.001)) "sleep counts as the step" 2.2 t.elapsed

let test_trust_root_parses () =
  Alcotest.(check bool)
    "the shipped signer file parses" true
    (match Trust_root.signers () with _ -> true);
  ignore (Trust_root.version ())

(* Revocation on the circle (docs/protocol.md, release_revocation) *)

let body_roundtrip (r : Release.revocation Release.signed) =
  (* Through text, as a relay stores and serves it. *)
  match
    Circle_revocation.of_body
      (Yojson.Safe.from_string
         (Yojson.Safe.to_string (Circle_revocation.to_body r)))
  with
  | Ok r -> r
  | Error e -> Alcotest.fail e

let test_circle_body_roundtrip () =
  let r = revocation ~by:[ mike ] roman in
  let r' = body_roundtrip r in
  Alcotest.(check string) "the document's exact bytes" r.bytes r'.bytes;
  Alcotest.(check int)
    "its signatures" 1
    (List.length
       (Release.valid_signers ~domain:Release.revocation_domain r'.bytes
          r'.signatures))

let test_circle_malformed () =
  let bad json =
    Alcotest.(check bool)
      (Yojson.Safe.to_string json)
      true
      (Result.is_error (Circle_revocation.of_body json))
  in
  bad
    (`Assoc [ ("document", `String "not base64url!"); ("signatures", `List []) ]);
  bad
    (`Assoc
       [ ("document", `String (B64url.encode "{}")); ("signatures", `List []) ]);
  bad (`Assoc [ ("signatures", `List []) ])

let receive_into dir (r : Release.revocation Release.signed) =
  let state_path = Filename.concat dir "update.json" in
  match
    Circle_revocation.receive_body ~state_path (Circle_revocation.to_body r)
  with
  | Ok o -> (o, state_path)
  | Error e -> Alcotest.fail e

let test_circle_revocation_persists_and_halts () =
  let dir = temp_dir () in
  let state_path = Filename.concat dir "update.json" in
  state_with_founders state_path;
  let outcome, _ = receive_into dir (revocation ~by:[ mike ] roman) in
  Alcotest.(check bool)
    (Circle_revocation.outcome_to_string outcome)
    true
    (match outcome with Circle_revocation.Revoked _ -> true | _ -> false);
  let s = loaded state_path in
  Alcotest.(check (list string))
    "persisted"
    [ Keys.public roman ]
    s.trust.revoked;
  let p = plan s.trust [ release ~by:[ mike; roman ] "0.2.0" ] in
  check_installs "with no revocation in the channel, updates still halt" None p;
  check_refused "says halted" "halted" p;
  let again, _ = receive_into dir (revocation ~by:[ mike ] roman) in
  Alcotest.(check bool)
    "a second copy is harmless" true
    (match again with
    | Circle_revocation.Already_revoked _ -> true
    | _ -> false)

let test_circle_revocation_outsider () =
  let dir = temp_dir () in
  let state_path = Filename.concat dir "update.json" in
  state_with_founders state_path;
  let before = State.read_file state_path in
  let check_ignored msg r =
    let outcome, _ = receive_into dir r in
    Alcotest.(check bool)
      msg true
      (match outcome with
      | Circle_revocation.Not_signed_by_a_current_signer _ -> true
      | _ -> false);
    Alcotest.(check string)
      (msg ^ ": state untouched")
      before
      (State.read_file state_path)
  in
  check_ignored "signed by a key outside the set"
    (revocation ~by:[ mallory ] roman);
  let r = revocation ~by:[ mike ] roman in
  check_ignored "a changed byte breaks the signature"
    { r with bytes = r.bytes ^ " " }

(* The node's schedule and the digest report *)

let test_due () =
  let r t = { Report.empty with last_checked_at = t } in
  let due ?(woke = false) now t = Schedule.due ~now ~woke (r t) in
  Alcotest.(check bool) "never checked" true (due 100. None);
  Alcotest.(check bool) "checked an hour ago" false (due 3_700. (Some 100.));
  Alcotest.(check bool)
    "a day later" true
    (due (100. +. Schedule.day) (Some 100.));
  Alcotest.(check bool)
    "on wake past the gap" true
    (due ~woke:true 3_700. (Some 100.));
  Alcotest.(check bool)
    "on wake inside the gap" false
    (due ~woke:true 200. (Some 100.));
  Alcotest.(check bool) "a clock that went back" true (due 50. (Some 100.))

let test_report_once () =
  let r = Report.record Report.empty ~now:1. [ "a"; "b"; "a" ] in
  Alcotest.(check (list string)) "first pass" [ "a"; "b" ] r.pending;
  let r = { r with pending = [] } in
  let r = Report.record r ~now:2. [ "a"; "b" ] in
  Alcotest.(check (list string)) "still there, not repeated" [] r.pending;
  let r = Report.record r ~now:3. [ "b" ] in
  let r = Report.record r ~now:4. [ "a"; "b" ] in
  Alcotest.(check (list string)) "gone and back is new" [ "a" ] r.pending;
  match Report.of_string (Report.to_string r) with
  | Ok r' ->
      Alcotest.(check string)
        "roundtrip" (Report.to_string r) (Report.to_string r')
  | Error e -> Alcotest.fail e

let schedule_config dir feed =
  Schedule.config ~base:feed
    ~platform:(fun () -> Ok platform)
    ~node_major:node24 ~dir ()

let test_schedule_switches () =
  let dir = temp_dir () in
  let feed = Filename.concat dir "feed/" in
  channel feed [ release ~by:[ mike; roman ] "0.2.0" ] ~tamper:false;
  let node = supervised_node () in
  let cfg = schedule_config node feed in
  (match Schedule.tick cfg ~now:1_000. ~woke:false with
  | Some (Schedule.Switched v', _) ->
      Alcotest.(check string) "switched" "0.2.0" (Version.to_string v')
  | _ -> Alcotest.fail "the first tick of a node did not switch");
  Alcotest.(check bool)
    "no pass while the switch is on trial" true
    (Schedule.tick cfg ~now:(1_000. +. Schedule.day) ~woke:false = None);
  Alcotest.(check (list string))
    "the switch says nothing until the supervisor decides" []
    (Report.take (Schedule.report_path node))

let test_report_drop_keeps_later_lines () =
  let path = Filename.concat (temp_dir ()) "update-report.json" in
  Report.save path (Report.record Report.empty ~now:1. [ "a" ]);
  let taken = (Report.load path).pending in
  Report.save path (Report.record (Report.load path) ~now:2. [ "a"; "b" ]);
  Report.drop path taken;
  Alcotest.(check (list string))
    "a line a pass added after the digest read the report stays" [ "b" ]
    (Report.load path).pending

let test_schedule_reports_refusal () =
  let dir = temp_dir () in
  let feed = Filename.concat dir "feed/" in
  channel feed [ release ~by:[ mike ] "0.2.0" ] ~tamper:false;
  let node = supervised_node () in
  let cfg = schedule_config node feed in
  (match Schedule.pass cfg ~now:1. with
  | Schedule.Not_switched, _ -> ()
  | (Schedule.Switched _ | Moved_back _), _ ->
      Alcotest.fail "a release one signer signed installed");
  ignore (Schedule.pass cfg ~now:(1. +. Schedule.day));
  let report = Report.load (Schedule.report_path node) in
  Alcotest.(check (list string))
    "reported once across two passes"
    [ "Release 0.2.0 was not installed: not signed by Roman." ]
    report.pending;
  Alcotest.(check bool)
    "the section is titled" true
    (Report.digest_section report = Some ("Updates", report.pending))

let test_schedule_reports_failure () =
  let dir = temp_dir () in
  let node = Filename.concat dir "node" in
  let cfg = schedule_config node (Filename.concat dir "no-such-feed/") in
  (match Schedule.pass cfg ~now:1. with
  | Schedule.Not_switched, [ line ] ->
      Alcotest.(check bool)
        ("a failed pass: " ^ line) true
        (contains ~sub:"The update check failed" line)
  | _ -> Alcotest.fail "an unreachable channel did not fail the pass");
  Alcotest.(check bool)
    "and the next pass waits a day" true
    (Schedule.tick cfg ~now:2. ~woke:false = None)

(* A recall (docs/releases.md, A recall) *)

let day = 86_400.

let recall ?(reason = "it loses mail") ~by version :
    Release.recall Release.signed =
  let bytes =
    Release.recall_to_string
      {
        recalled_version = v version;
        reason;
        recalled_at = "2026-11-01T00:00:00.000Z";
      }
  in
  let doc =
    match Release.recall_of_string bytes with
    | Ok d -> d
    | Error e -> failwith e
  in
  { bytes; doc; signatures = sign_all ~domain:Release.recall_domain by bytes }

let test_recalled_never_installs () =
  let p =
    Policy.plan
      ~recalls:[ recall ~by:[ roman ] "0.2.0" ]
      ~installed:(v "0.1.0") ~pin:None ~platform (trust founders)
      ~revocations:[]
      [ release ~by:[ mike; roman ] "0.2.0" ]
  in
  check_installs "a version one signer recalled is refused" None p;
  check_refused "names who recalled it and why"
    "recalled by Roman: it loses mail" p;
  let p =
    Policy.plan
      ~recalls:[ recall ~by:[ roman ] "0.2.0" ]
      ~installed:(v "0.1.0") ~pin:None ~platform (trust founders)
      ~revocations:[]
      [
        release ~by:[ mike; roman ] "0.2.0"; release ~by:[ mike; roman ] "0.2.1";
      ]
  in
  check_installs "the next version both sign is the way forward" (Some "0.2.1")
    p

let test_recall_counts_only_current_keys () =
  let r = recall ~by:[ carol ] "0.2.0" in
  Alcotest.(check bool)
    "an outsider's recall counts for nothing" true
    (Policy.recall_of (trust founders) [ r ] (v "0.2.0") = None);
  let revoked = { (trust founders) with revoked = [ Keys.public roman ] } in
  Alcotest.(check bool)
    "a revoked key's recall stops counting" true
    (Policy.recall_of revoked [ recall ~by:[ roman ] "0.2.0" ] (v "0.2.0")
    = None);
  let replaced = trust [ signer "Mike" mike; signer "Carol" carol ] in
  Alcotest.(check bool)
    "so does a key the signer set no longer holds" true
    (Policy.recall_of replaced [ recall ~by:[ roman ] "0.2.0" ] (v "0.2.0")
    = None);
  match
    Policy.recall_of (trust founders)
      [
        recall ~by:[ roman ] "0.2.0"; recall ~reason:"same" ~by:[ mike ] "0.2.0";
      ]
      (v "0.2.0")
  with
  | Some r ->
      Alcotest.(check bool) "two documents, both signers" true r.every_signer
  | None -> Alcotest.fail "two current signers' recalls did not count"

(* A supervised node holding [versions] on disk, each first installed at its time, running
   [running]. *)
let node_with versions ~running =
  let node = temp_dir () in
  List.iter
    (fun (ver, _) ->
      let root = Layout.release_dir node ver in
      write (Layout.binary_in root) (script ver);
      Unix.chmod (Layout.binary_in root) 0o755;
      write (Layout.marker_in root)
        (Layout.marker_json ~version:(v ver) ~source:"test"))
    versions;
  Layout.point_current node running;
  Layout.point_good node running;
  State.save (Schedule.state_path node)
    {
      (State.initial ()) with
      installed = v running;
      trust = trust founders;
      first_installed = List.map (fun (ver, at) -> (v ver, at)) versions;
    };
  node

let apply_recalls ?(now = 20. *. day) node recalls =
  let state = loaded (Schedule.state_path node) in
  snd (Recall.apply ~dir:node ~now ~trust:state.trust ~recalls state)

let moved_to = function
  | Recall.Moved_back { to_; _ } -> Some (Version.to_string to_)
  | _ -> None

let stayed_line = function
  | Recall.Stayed { line; _ } -> line
  | Recall.Moved_back { line; _ } -> Alcotest.failf "moved: %s" line
  | Recall.Not_recalled -> Alcotest.fail "the recall was not seen"

let test_recall_moves_back () =
  let node =
    node_with [ ("0.1.6", 2. *. day); ("0.1.7", 18. *. day) ] ~running:"0.1.7"
  in
  let o = apply_recalls node [ recall ~by:[ roman ] "0.1.7" ] in
  Alcotest.(check (option string)) "moved back" (Some "0.1.6") (moved_to o);
  Alcotest.(check string) "current" "0.1.6" (current node);
  Alcotest.(check (option string)) "good" (Some "0.1.6") (Layout.good node);
  let s = loaded (Schedule.state_path node) in
  Alcotest.(check string) "installed" "0.1.6" (Version.to_string s.installed);
  Alcotest.(check (option (float 0.)))
    "a move back never resets a first install"
    (Some (18. *. day))
    (State.first_installed_at s (v "0.1.7"));
  (match o with
  | Moved_back { line; _ } ->
      Alcotest.(check string)
        "the digest's line"
        "Digestif 0.1.7 was recalled by Roman: it loses mail. This node went \
         back to 0.1.6."
        line
  | _ -> ());
  Alcotest.(check bool)
    "the older release runs now, and nothing recalls it" true
    (apply_recalls node [ recall ~by:[ roman ] "0.1.7" ] = Recall.Not_recalled)

let test_recall_week_limit () =
  let node =
    node_with [ ("0.1.6", 1. *. day); ("0.1.7", 5. *. day) ] ~running:"0.1.7"
  in
  let line =
    stayed_line (apply_recalls node [ recall ~by:[ roman ] "0.1.7" ])
  in
  Alcotest.(check bool)
    ("one signer cannot move a node off a version it ran past a week: " ^ line)
    true
    (contains ~sub:"has run 0.1.7 for more than a week" line);
  Alcotest.(check string) "current stays" "0.1.7" (current node);
  Alcotest.(check (option string))
    "both signers have no limit" (Some "0.1.6")
    (moved_to (apply_recalls node [ recall ~by:[ mike; roman ] "0.1.7" ]))

(* One signer's recalls cannot walk a node down releases/: the floor is the newest release the node
   first installed more than a week ago. *)
let test_chained_recalls_stop_at_the_floor () =
  let versions =
    [ ("0.1.5", 0.); ("0.1.6", 1. *. day); ("0.1.7", 12. *. day) ]
  in
  let now = 14. *. day in
  let node = node_with versions ~running:"0.1.7" in
  Alcotest.(check (option string))
    "the first recall moves back a week's worth" (Some "0.1.6")
    (moved_to (apply_recalls ~now node [ recall ~by:[ roman ] "0.1.7" ]));
  let line =
    stayed_line
      (apply_recalls ~now node
         [ recall ~by:[ roman ] "0.1.7"; recall ~by:[ roman ] "0.1.6" ])
  in
  Alcotest.(check bool)
    ("a second recall does not take it further: " ^ line)
    true
    (contains ~sub:"has run 0.1.6 for more than a week" line);
  Alcotest.(check string) "current stays at 0.1.6" "0.1.6" (current node);
  let node = node_with versions ~running:"0.1.7" in
  let line =
    stayed_line
      (apply_recalls ~now node
         [ recall ~by:[ roman ] "0.1.6"; recall ~by:[ roman ] "0.1.7" ])
  in
  Alcotest.(check bool)
    ("recalling the floor first does not open the way below it: " ^ line)
    true
    (contains ~sub:"ran 0.1.6 for more than a week" line);
  Alcotest.(check string) "current stays at 0.1.7" "0.1.7" (current node)

let test_recall_nothing_older () =
  let node = node_with [ ("0.1.7", 19. *. day) ] ~running:"0.1.7" in
  Alcotest.(check string)
    "stays"
    "Digestif 0.1.7 was recalled by Roman: it loses mail. This node has \
     nothing to go back to, so it keeps running 0.1.7 until the next release."
    (stayed_line (apply_recalls node [ recall ~by:[ roman ] "0.1.7" ]))

let test_recall_failed_self_test () =
  (* The fake 0.3.0 binary fails its self-test. *)
  let node =
    node_with [ ("0.3.0", 2. *. day); ("0.3.1", 18. *. day) ] ~running:"0.3.1"
  in
  let line =
    stayed_line (apply_recalls node [ recall ~by:[ roman ] "0.3.1" ])
  in
  Alcotest.(check bool)
    ("names the self-test: " ^ line)
    true
    (contains ~sub:"Going back to 0.3.0 failed its self-test" line);
  Alcotest.(check string) "current stays" "0.3.1" (current node)

(* A version that keeps crashing (Supervisor, Crashes). Each call is one supervisor the service
   manager started, whose child exits after [ran] seconds of awake time. *)
let crash_once ?(ran = 60) ?(spawn = fun () -> ()) node =
  let crashes = ref [] in
  let ops =
    let ops = sim_ops ~exit_at:(Some ran) node (new_sim ()) in
    {
      ops with
      spawn =
        (fun exe ->
          spawn ();
          ops.spawn exe);
    }
  in
  let status =
    Supervisor.run ~on_crash:(fun c -> crashes := c :: !crashes) ops node
  in
  Alcotest.(check bool) "the child's exit" true (status = Supervisor.Exited 1);
  !crashes

let exits_counted node ~release = List.length (Crashes.load node ~release).exits

let test_crashing_version_goes_back () =
  let node = node_with [ ("0.1.6", 0.); ("0.1.7", day) ] ~running:"0.1.7" in
  Alcotest.(check int) "first exit" 0 (List.length (crash_once node));
  Alcotest.(check int) "second exit" 0 (List.length (crash_once node));
  Alcotest.(check int) "counted on disk" 2 (exits_counted node ~release:"0.1.7");
  Alcotest.(check string) "still on 0.1.7" "0.1.7" (current node);
  (match crash_once node with
  | [ Supervisor.Crashed_back (from, to_) ] ->
      Alcotest.(check (pair string string))
        "the third exit moves back" ("0.1.7", "0.1.6")
        (Version.to_string from, Version.to_string to_)
  | _ -> Alcotest.fail "expected one move back");
  Alcotest.(check string) "current" "0.1.6" (current node);
  Alcotest.(check (option string)) "good" (Some "0.1.6") (Layout.good node);
  let s = loaded (Schedule.state_path node) in
  Alcotest.(check string) "installed" "0.1.6" (Version.to_string s.installed);
  Alcotest.(check bool) "refused" true (State.is_refused s (v "0.1.7"));
  Alcotest.(check bool)
    "the count starts over" false
    (Sys.file_exists (Layout.crashes_path node));
  Alcotest.(check (list string))
    "the digest says so"
    [ "Digestif 0.1.7 kept crashing, so this node went back to 0.1.6." ]
    (Report.take (Schedule.report_path node))

(* Exits five awake minutes apart: never three within ten minutes. *)
let test_spread_crashes_stay () =
  let node = node_with [ ("0.1.6", 0.); ("0.1.7", day) ] ~running:"0.1.7" in
  for _ = 1 to 5 do
    Alcotest.(check int) "no move" 0 (List.length (crash_once ~ran:300 node))
  done;
  Alcotest.(check string) "still on 0.1.7" "0.1.7" (current node);
  Alcotest.(check int)
    "only the window's exits are kept" 2
    (exits_counted node ~release:"0.1.7");
  Alcotest.(check bool)
    "not refused" false
    (State.is_refused (loaded (Schedule.state_path node)) (v "0.1.7"))

let test_crash_nothing_older () =
  let node = node_with [ ("0.1.7", 0.) ] ~running:"0.1.7" in
  ignore (crash_once node);
  ignore (crash_once node);
  (match crash_once node with
  | [ Supervisor.Crashed_stayed _ ] -> ()
  | _ -> Alcotest.fail "expected the node to stay");
  Alcotest.(check string) "current stays" "0.1.7" (current node);
  Alcotest.(check bool)
    "the version it runs is not refused" false
    (State.is_refused (loaded (Schedule.state_path node)) (v "0.1.7"));
  Alcotest.(check (list string))
    "the digest says so"
    [
      "Digestif 0.1.7 kept crashing, and this node has nothing older to go \
       back to, so it keeps restarting until the next release.";
    ]
    (Report.take (Schedule.report_path node))

let test_crash_older_self_test_fails () =
  (* The fake 0.3.0 binary fails its self-test. *)
  let node = node_with [ ("0.3.0", 0.); ("0.3.1", day) ] ~running:"0.3.1" in
  ignore (crash_once node);
  ignore (crash_once node);
  ignore (crash_once node);
  Alcotest.(check string) "current stays" "0.3.1" (current node);
  Alcotest.(check bool)
    "names the self-test" true
    (List.exists
       (contains ~sub:"going back to 0.3.0 failed its self-test")
       (Report.take (Schedule.report_path node)))

(* An exit after which current names another release is the child's own move back (a recall), and
   the count belongs to the release that ran. *)
let test_crash_count_follows_the_release () =
  let node = node_with [ ("0.1.6", 0.); ("0.1.7", day) ] ~running:"0.1.7" in
  ignore (crash_once node);
  ignore (crash_once node);
  let recalled () =
    Layout.point_current node "0.1.6";
    Layout.point_good node "0.1.6"
  in
  Alcotest.(check int)
    "a recall's exit is not a crash" 0
    (List.length (crash_once ~spawn:recalled node));
  Alcotest.(check int) "0.1.7's count" 2 (exits_counted node ~release:"0.1.7");
  ignore (crash_once node);
  Alcotest.(check int)
    "0.1.6 counts from nothing" 1
    (exits_counted node ~release:"0.1.6");
  Alcotest.(check bool)
    "0.1.7 was not refused by the supervisor" false
    (State.is_refused (loaded (Schedule.state_path node)) (v "0.1.7"))

let test_stop_is_not_a_crash () =
  let node = node_with [ ("0.1.6", 0.); ("0.1.7", day) ] ~running:"0.1.7" in
  let ops = { (sim_ops node (new_sim ())) with stopping = (fun () -> true) } in
  Alcotest.(check bool)
    "exits 0" true
    (Supervisor.run ops node = Supervisor.Exited 0);
  Alcotest.(check bool)
    "nothing counted" false
    (Sys.file_exists (Layout.crashes_path node))

(* A recall in a channel on disk, written the way `digestif-update recall` writes it. *)
let recall_in_channel feed ~secret ?(reason = "it loses mail") version =
  match
    Recall_channel.write_recall ~dir:feed ~secret ~version:(v version) ~reason
      ~recalled_at:"2026-11-01T00:00:00.000Z"
  with
  | Ok w -> w
  | Error e -> Alcotest.fail e

let test_recall_channel_write () =
  let dir = temp_dir () in
  let feed = Filename.concat dir "feed/" in
  channel feed [ release ~by:[ mike; roman ] "0.2.0" ] ~tamper:false;
  (match
     Recall_channel.write_recall ~dir:feed ~secret:roman ~version:(v "0.9.0")
       ~reason:"typo" ~recalled_at:"2026-11-01T00:00:00.000Z"
   with
  | Ok _ -> Alcotest.fail "a version the channel never published was recalled"
  | Error e ->
      Alcotest.(check bool)
        ("refused: " ^ e) true
        (contains ~sub:"publishes no release 0.9.0" e));
  let first = recall_in_channel feed ~secret:roman "0.2.0" in
  Alcotest.(check bool) "wrote it" true first.first;
  let second =
    recall_in_channel feed ~secret:mike ~reason:"another reason" "0.2.0"
  in
  Alcotest.(check bool) "signed the same document" false second.first;
  Alcotest.(check string)
    "the first reason stands" "it loses mail" second.recall.doc.reason;
  ignore (recall_in_channel feed ~secret:mike "0.2.0");
  match Feed.read Feed.default_fetch ~base:feed ~installed:(v "0.1.0") with
  | Error e -> Alcotest.fail e
  | Ok f -> (
      Alcotest.(check int) "listed once" 1 (List.length f.recalls);
      Alcotest.(check (list string)) "no problems" [] f.problems;
      match Policy.recall_of (trust founders) f.recalls (v "0.2.0") with
      | Some r ->
          Alcotest.(check bool) "both signers, read back" true r.every_signer
      | None -> Alcotest.fail "the channel's recall did not count")

let feed_with releases =
  let dir = temp_dir () in
  let feed = Filename.concat dir "feed/" in
  channel feed releases ~tamper:false;
  feed

(* `digestif-update recall` with no --key reads the key from the command signer.json names, as
   sign --next does, and with no signer.json says what to write there. *)
let recall_cli ~config feed =
  let dir = temp_dir () in
  let out = Filename.concat dir "out" and err = Filename.concat dir "err" in
  let code =
    Sys.command
      (Printf.sprintf
         "XDG_CONFIG_HOME=%s ../bin/main.exe recall 0.2.0 --reason 'it loses \
          mail' --channel %s --data-dir %s >%s 2>%s"
         (Filename.quote config) (Filename.quote feed)
         (Filename.quote (Filename.concat dir "no-node"))
         (Filename.quote out) (Filename.quote err))
  in
  let all f = In_channel.with_open_bin f In_channel.input_all in
  (code, all out, all err)

let test_recall_reads_signer_json () =
  let feed = feed_with [ release ~by:[ mike; roman ] "0.2.0" ] in
  let config = temp_dir () in
  let key = Filename.concat config "roman.key" in
  Out_channel.with_open_bin key (fun oc ->
      Out_channel.output_string oc (Keys.encode_secret roman ^ "\n"));
  let code, _, err = recall_cli ~config feed in
  Alcotest.(check int) "no signer.json: exit 1" 1 code;
  Alcotest.(check bool)
    ("names signer.json: " ^ err)
    true
    (contains ~sub:"digestif/signer.json does not exist" err);
  Sys.mkdir (Filename.concat config "digestif") 0o700;
  Out_channel.with_open_bin (Filename.concat config "digestif/signer.json")
    (fun oc ->
      Out_channel.output_string oc
        (Yojson.Safe.to_string
           (`Assoc [ ("key_command", `String ("cat " ^ Filename.quote key)) ])));
  let code, out, err = recall_cli ~config feed in
  Alcotest.(check int) ("exit 0: " ^ err) 0 code;
  Alcotest.(check bool)
    ("recalled: " ^ out) true
    (contains ~sub:"recalled 0.2.0 in" out);
  match Feed.read Feed.default_fetch ~base:feed ~installed:(v "0.1.0") with
  | Error e -> Alcotest.fail e
  | Ok f -> (
      match Policy.recall_of (trust founders) f.recalls (v "0.2.0") with
      | Some r ->
          Alcotest.(check bool) "one signer's recall" false r.every_signer
      | None ->
          Alcotest.fail "the recall signed with signer.json's key did not count"
      )

let test_update_pass_obeys_recall () =
  let feed =
    feed_with
      [
        release ~by:[ mike; roman ] "0.1.6"; release ~by:[ mike; roman ] "0.1.7";
      ]
  in
  ignore (recall_in_channel feed ~secret:roman "0.1.7");
  let node =
    node_with [ ("0.1.6", 2. *. day); ("0.1.7", 18. *. day) ] ~running:"0.1.7"
  in
  let o = update ~now:(20. *. day) ~feed node in
  Alcotest.(check bool)
    "moved back" true
    (match o.step with
    | Updater.Moved_back (f, t, _) -> f = v "0.1.7" && t = v "0.1.6"
    | _ -> false);
  Alcotest.(check string)
    "update.json says 0.1.6" "0.1.6"
    (Version.to_string (loaded (Schedule.state_path node)).installed);
  let again = update ~now:(20. *. day) ~feed node in
  Alcotest.(check bool) "and stays there" true (again.step = Updater.Nothing);
  Alcotest.(check bool)
    "the recalled version is refused, not installed again" true
    (List.exists
       (fun (s : Policy.skipped) -> s.skipped_version = v "0.1.7")
       again.plan.skipped)

let test_newer_release_beats_recall () =
  let feed =
    feed_with
      [
        release ~by:[ mike; roman ] "0.1.7"; release ~by:[ mike; roman ] "0.2.0";
      ]
  in
  ignore (recall_in_channel feed ~secret:roman "0.1.7");
  let node =
    node_with [ ("0.1.6", 2. *. day); ("0.1.7", 18. *. day) ] ~running:"0.1.7"
  in
  let o = update ~now:(20. *. day) ~feed node in
  Alcotest.(check bool)
    "a newer release is taken rather than moving back" true
    (o.step = Updater.Switched (v "0.2.0"))

let test_circle_recall_starts_a_pass () =
  let feed = feed_with [ release ~by:[ mike; roman ] "0.1.7" ] in
  let node =
    node_with [ ("0.1.6", 2. *. day); ("0.1.7", 18. *. day) ] ~running:"0.1.7"
  in
  let circle = ref [] in
  let cfg =
    Schedule.config ~base:feed
      ~platform:(fun () -> Ok platform)
      ~node_major:node24
      ~circle:(fun () -> !circle)
      ~dir:node ()
  in
  let now = 20. *. day in
  (match Schedule.tick cfg ~now ~woke:false with
  | Some (Schedule.Not_switched, _) -> ()
  | _ -> Alcotest.fail "the first pass did something");
  Alcotest.(check bool)
    "nothing due" true
    (Schedule.tick cfg ~now:(now +. 60.) ~woke:false = None);
  let r = recall ~by:[ roman ] "0.1.7" in
  (* Through text, as a relay stores and serves it. *)
  (circle :=
     match
       Circle_recall.of_body
         (Yojson.Safe.from_string
            (Yojson.Safe.to_string (Circle_recall.to_body r)))
     with
     | Ok r -> [ r ]
     | Error e -> Alcotest.fail e);
  (match Schedule.tick cfg ~now:(now +. 120.) ~woke:false with
  | Some (Schedule.Moved_back (f, t), _) ->
      Alcotest.(check (pair string string))
        "a recall on the circle moves the node at once" ("0.1.7", "0.1.6")
        (Version.to_string f, Version.to_string t)
  | _ -> Alcotest.fail "a recall on the circle did not start a pass");
  Alcotest.(check (list string))
    "the digest says so once"
    [
      "Digestif 0.1.7 was recalled by Roman: it loses mail. This node went \
       back to 0.1.6.";
    ]
    (Report.take (Schedule.report_path node));
  Alcotest.(check bool)
    "a recall already counted starts nothing" true
    (Schedule.tick cfg ~now:(now +. 180.) ~woke:false = None)

let test_promote_records_first_install () =
  let node = switched_node () in
  let sim = new_sim () in
  ignore (trial_outcome (sim_ops ~healthy_at:(Some (3, "0.2.0")) node sim) node);
  Alcotest.(check bool)
    "a healthy switch records its first install" true
    (State.first_installed_at (loaded (Schedule.state_path node)) (v "0.2.0")
    <> None)

(* ci/platforms.json and the manifest's check against it. *)
let shipped_json =
  {|{ "platforms": [ { "platform": "darwin-arm64", "runner": "macos-15" },
      { "platform": "linux-x86_64", "runner": "ubuntu-24.04" },
      { "platform": "linux-arm64", "runner": "ubuntu-24.04-arm" } ] }|}

let shipped () =
  match Platform.shipped_of_string shipped_json with
  | Ok ps -> ps
  | Error e -> Alcotest.fail e

let test_shipped_parses () =
  Alcotest.(check (list string))
    "names"
    [ "darwin-arm64"; "linux-x86_64"; "linux-arm64" ]
    (shipped ());
  Alcotest.(check bool)
    "an entry without a name is refused" true
    (Result.is_error
       (Platform.shipped_of_string {|{ "platforms": [ { "runner": "x" } ] }|}))

let test_shipped_all_named () =
  Alcotest.(check bool)
    "every platform once" true
    (Platform.check_shipped ~shipped:(shipped ())
       [ "linux-arm64"; "darwin-arm64"; "linux-x86_64" ]
    = Ok ())

let test_shipped_missing_one () =
  match
    Platform.check_shipped ~shipped:(shipped ())
      [ "darwin-arm64"; "linux-x86_64" ]
  with
  | Ok () -> Alcotest.fail "a manifest without linux-arm64 passed"
  | Error e ->
      Alcotest.(check bool)
        ("names the missing platform: " ^ e)
        true
        (contains ~sub:"missing linux-arm64" e)

let test_shipped_unknown_and_twice () =
  match
    Platform.check_shipped ~shipped:(shipped ())
      [
        "darwin-arm64";
        "darwin-arm64";
        "linux-x86_64";
        "linux-arm64";
        "darwin-x86_64";
      ]
  with
  | Ok () -> Alcotest.fail "an unknown and a repeated platform passed"
  | Error e ->
      Alcotest.(check bool)
        ("unknown: " ^ e) true
        (contains ~sub:"darwin-x86_64" e);
      Alcotest.(check bool)
        ("twice: " ^ e) true
        (contains ~sub:"named twice: darwin-arm64" e)

(* sign --next against a fake gh: what it asks, what it uploads, what it deletes. *)

let gh_releases ?(signed_by = []) () =
  let asset id name = `Assoc [ ("id", `Int id); ("name", `String name) ] in
  Yojson.Safe.to_string
    (`List
       [
         `Assoc
           [
             ("tag_name", `String "v0.2.1");
             ("draft", `Bool true);
             ( "assets",
               `List
                 (asset 21 "manifest.json"
                 :: List.mapi
                      (fun i k ->
                        asset (30 + i) (Sign_next.signature_asset_name k))
                      signed_by) );
           ];
         `Assoc
           [
             ("tag_name", `String "v0.2.0");
             ("draft", `Bool false);
             ("assets", `List [ asset 11 "manifest.json" ]);
           ];
         `Assoc [ ("tag_name", `String "nightly"); ("draft", `Bool true) ];
       ])

type fake = {
  calls : string list list ref;
  uploaded : string option ref;
  keys_read : int ref;
}

let fake_gh ?signed_by ?(manifest = manifest_json "0.2.1") () =
  let f = { calls = ref []; uploaded = ref None; keys_read = ref 0 } in
  let gh args =
    f.calls := !(f.calls) @ [ args ];
    match args with
    | [ "api"; "repos/o/r/releases?per_page=50" ] ->
        Ok (gh_releases ?signed_by ())
    | [ "api"; "-H"; _; "repos/o/r/releases/assets/21" ] -> Ok manifest
    | [ "api"; "repos/o/r/commits/v0.2.1"; "--jq"; ".sha" ] -> Ok "abc123\n"
    | "api" :: run :: _ when contains ~sub:"actions/workflows" run ->
        Ok "https://github.com/o/r/actions/runs/7\n"
    | [ "api"; "repos/o/r/compare/v0.2.0...v0.2.1"; "--jq"; _ ] ->
        Ok "Fix the digest\nAdd a recall\n"
    | [ "release"; "upload"; "v0.2.1"; path; "--repo"; "o/r"; "--clobber" ] ->
        f.uploaded := Some path;
        Ok ""
    | [ "release"; "delete"; "v0.2.1"; "--repo"; "o/r"; "--yes" ] -> Ok ""
    | _ -> Error ("unexpected gh " ^ String.concat " " args)
  in
  (f, gh)

let run_next ?signed_by ?manifest ?(key = mike) answer =
  let f, gh = fake_gh ?signed_by ?manifest () in
  let said = Buffer.create 256 in
  let read_key () =
    incr f.keys_read;
    Ok (Keys.encode_secret key ^ "\n")
  in
  let result =
    Sign_next.run ~gh ~signers:founders
      ~config:{ Sign_next.key_command = "unused"; repo = "o/r" }
      ~read_key
      ~ask:(fun _ -> answer)
      ~say:(fun l -> Buffer.add_string said (l ^ "\n"))
      ~tmp:(temp_dir ()) ~relay:Sign_next.no_relay
  in
  (f, result, Buffer.contents said)

let test_sign_next_signs () =
  let f, result, said = run_next "s\n" in
  (match result with Ok () -> () | Error e -> Alcotest.fail e);
  List.iter
    (fun sub ->
      Alcotest.(check bool) ("shows " ^ sub) true (contains ~sub said))
    [
      "Digestif 0.2.1";
      "abc123";
      "actions/runs/7";
      "- Fix the digest";
      "- Add a recall";
      "https://github.com/o/r/compare/v0.2.0...v0.2.1";
      Keys.hash_of_bytes (binary_bytes "0.2.1");
      "Nobody has signed it yet.";
    ];
  Alcotest.(check int) "the key is read once" 1 !(f.keys_read);
  match !(f.uploaded) with
  | None -> Alcotest.fail "nothing was uploaded"
  | Some path -> (
      Alcotest.(check string)
        "the asset is named for the key"
        (Sign_next.signature_asset_name (Keys.public mike))
        (Filename.basename path);
      match
        Release.signatures_of_string
          (In_channel.with_open_bin path In_channel.input_all)
      with
      | Error e -> Alcotest.fail e
      | Ok sigs ->
          Alcotest.(check (list string))
            "one valid signature, by the signer"
            [ Keys.public mike ]
            (Release.valid_signers ~domain:Release.release_domain
               (manifest_json "0.2.1") sigs))

let test_sign_next_drops () =
  let f, result, said = run_next "d\n" in
  (match result with Ok () -> () | Error e -> Alcotest.fail e);
  Alcotest.(check int) "no key is read" 0 !(f.keys_read);
  Alcotest.(check bool) "nothing uploaded" true (!(f.uploaded) = None);
  Alcotest.(check bool)
    "the draft is deleted" true
    (List.mem
       [ "release"; "delete"; "v0.2.1"; "--repo"; "o/r"; "--yes" ]
       !(f.calls));
  Alcotest.(check bool)
    ("says so: " ^ said) true
    (contains ~sub:"Dropped v0.2.1" said)

let test_sign_next_leaves () =
  let f, result, _ = run_next "\n" in
  (match result with Ok () -> () | Error e -> Alcotest.fail e);
  Alcotest.(check int) "no key is read" 0 !(f.keys_read);
  Alcotest.(check bool)
    "nothing uploaded or deleted" true
    (!(f.uploaded) = None
    && not (List.exists (fun c -> List.mem "delete" c) !(f.calls)))

let test_sign_next_outsider_key () =
  let f, result, _ = run_next ~key:mallory "s" in
  (match result with
  | Ok () -> Alcotest.fail "an outsider's key signed"
  | Error e ->
      Alcotest.(check bool)
        ("names the key: " ^ e) true
        (contains ~sub:"is not a release signer" e));
  Alcotest.(check bool) "nothing uploaded" true (!(f.uploaded) = None)

let test_sign_next_wrong_version () =
  let f, result, _ = run_next ~manifest:(manifest_json "0.2.2") "s" in
  (match result with
  | Ok () -> Alcotest.fail "a manifest of another version was offered"
  | Error e ->
      Alcotest.(check bool)
        ("refused: " ^ e) true
        (contains ~sub:"names version 0.2.2" e));
  Alcotest.(check int) "no key is read" 0 !(f.keys_read)

let test_sign_next_shows_who_signed () =
  let _, _, said = run_next ~signed_by:[ Keys.public roman ] "" in
  Alcotest.(check bool)
    ("names Roman: " ^ said) true
    (contains ~sub:"Already signed by: Roman" said);
  Alcotest.(check bool)
    ("says the second signature publishes it: " ^ said)
    true
    (contains ~sub:"One more signature publishes it." said)

(* sign --next's relay line and relay-publish against a fake gh (docs/releases.md, Signing a relay
   release and Publishing a relay release). *)

let migration_text = "ALTER TABLE circle ADD COLUMN relay_version TEXT;\n"

let relay_doc ~migrations version =
  let m =
    relay_manifest ~compatible_with:"0.2.0" ~notes:"Report the version." version
  in
  {
    m with
    migrations =
      List.map
        (fun (name, text) ->
          {
            Release.migration = name;
            migration_sha256 = Keys.hash_of_bytes text;
          })
        migrations;
  }

let base_migrations =
  [ ("0001_init.sql", "init"); ("0002_mailer.sql", "mailer") ]

let doc_030 =
  relay_doc
    ~migrations:
      (base_migrations @ [ ("0003_relay_version.sql", migration_text) ])
    "0.3.0"

let bytes_030 = Release.relay_manifest_to_string doc_030

let bytes_020 =
  Release.relay_manifest_to_string
    (relay_doc ~migrations:base_migrations "0.2.0")

let relay_sig_asset secret =
  Release.signatures_to_string
    (Release.add_signature ~domain:Release.relay_release_domain ~secret
       bytes_030 [])

let relay_listing ?(node_draft = false) ?(draft = true) ~signed_by () =
  let asset ?digest id name =
    `Assoc
      ([ ("id", `Int id); ("name", `String name) ]
      @ match digest with Some d -> [ ("digest", `String d) ] | None -> [])
  in
  Yojson.Safe.to_string
    (`List
       ([
          `Assoc
            [
              ("tag_name", `String "relay-v0.3.0");
              ("draft", `Bool draft);
              ( "assets",
                `List
                  ([
                     asset 51 "manifest.json";
                     asset ~digest:doc_030.bundle.bundle_sha256 52
                       "digestif-relay-0.3.0.tar.gz";
                   ]
                  @ List.map
                      (fun (id, k) ->
                        asset id
                          (Sign_next.signature_asset_name (Keys.public k)))
                      signed_by) );
            ];
          `Assoc
            [
              ("tag_name", `String "relay-v0.2.0");
              ("draft", `Bool false);
              ("assets", `List [ asset 41 "manifest.json" ]);
            ];
          `Assoc
            [
              ("tag_name", `String "v0.2.0");
              ("draft", `Bool false);
              ("assets", `List [ asset 11 "manifest.json" ]);
            ];
        ]
       @
       if node_draft then
         [
           `Assoc
             [
               ("tag_name", `String "v0.2.1");
               ("draft", `Bool true);
               ("assets", `List [ asset 21 "manifest.json" ]);
             ];
         ]
       else []))

type relay_fake = {
  r_calls : string list list ref;
  r_uploaded : string option ref;
}

let relay_gh ?node_draft ?draft ~signed_by () =
  let f = { r_calls = ref []; r_uploaded = ref None } in
  let gh args =
    f.r_calls := !(f.r_calls) @ [ args ];
    match args with
    | [ "api"; "repos/o/r/releases?per_page=50" ] ->
        Ok (relay_listing ?node_draft ?draft ~signed_by ())
    | [ "api"; "-H"; _; "repos/o/r/releases/assets/51" ] -> Ok bytes_030
    | [ "api"; "-H"; _; "repos/o/r/releases/assets/41" ] -> Ok bytes_020
    | [ "api"; "-H"; _; "repos/o/r/releases/assets/21" ] ->
        Ok (manifest_json "0.2.1")
    | [ "api"; "-H"; _; "repos/o/r/releases/assets/53" ] ->
        Ok (relay_sig_asset mike)
    | [ "api"; "-H"; _; "repos/o/r/releases/assets/54" ] ->
        Ok (relay_sig_asset roman)
    | [ "api"; "repos/o/r/commits/relay-v0.3.0"; "--jq"; ".sha" ] ->
        Ok "def456\n"
    | [ "api"; "repos/o/r/commits/v0.2.1"; "--jq"; ".sha" ] -> Ok "abc123\n"
    | "api" :: run :: _
      when contains ~sub:"actions/workflows/relay-release.yml" run ->
        Ok "https://github.com/o/r/actions/runs/9\n"
    | "api" :: run :: _ when contains ~sub:"actions/workflows" run ->
        Ok "https://github.com/o/r/actions/runs/7\n"
    | [ "api"; "repos/o/r/compare/relay-v0.2.0...relay-v0.3.0"; "--jq"; _ ] ->
        Ok
          "aaa\tReport the relay version\n\
           bbb\tA relay test only\n\
           ccc\tA node change\n"
    | [ "api"; "repos/o/r/compare/v0.2.0...v0.2.1"; "--jq"; _ ] ->
        Ok "Fix the digest\n"
    | [
     "api";
     "-H";
     _;
     "repos/o/r/contents/ci/relay-release-paths?ref=relay-v0.3.0";
    ] ->
        Ok
          "# the relay\n\
           relay/src\n\
           relay/migrations\n\
           :(exclude,glob)relay/**/*.test.ts\n"
    | [ "api"; "repos/o/r/commits/aaa"; "--jq"; _ ] ->
        Ok "relay/src/read.ts\nnode/x.ml\n"
    | [ "api"; "repos/o/r/commits/bbb"; "--jq"; _ ] ->
        Ok "relay/src/read.test.ts\n"
    | [ "api"; "repos/o/r/commits/ccc"; "--jq"; _ ] -> Ok "node/core/fold.ml\n"
    | [
     "api";
     "-H";
     _;
     "repos/o/r/contents/relay/migrations/0003_relay_version.sql?ref=relay-v0.3.0";
    ] ->
        Ok migration_text
    | [ "release"; "upload"; _; path; "--repo"; "o/r"; "--clobber" ] ->
        f.r_uploaded := Some path;
        Ok ""
    | [
     "release";
     "edit";
     "relay-v0.3.0";
     "--repo";
     "o/r";
     "--draft=false";
     "--latest=false";
    ] ->
        Ok ""
    | _ -> Error ("unexpected gh " ^ String.concat " " args)
  in
  (f, gh)

let run_relay ?node_draft ?(signed_by = []) ?(key = mike) ?(answers = [ "s" ])
    () =
  let f, gh = relay_gh ?node_draft ~signed_by () in
  let said = Buffer.create 1024 in
  let published = ref [] in
  let answers = ref answers in
  let relay : Sign_next.relay =
    {
      relay_versions =
        (fun () ->
          Some
            [
              ("https://dinners.digestif.io", Ok (Some "0.2.0"));
              ("https://dinners-roman.example", Ok None);
            ]);
      publish =
        (fun v ->
          published := v :: !published;
          Ok ());
    }
  in
  let result =
    Sign_next.run ~gh ~signers:founders
      ~config:{ Sign_next.key_command = "unused"; repo = "o/r" }
      ~read_key:(fun () -> Ok (Keys.encode_secret key ^ "\n"))
      ~ask:(fun _ ->
        match !answers with
        | a :: rest ->
            answers := rest;
            a
        | [] -> "")
      ~say:(fun l -> Buffer.add_string said (l ^ "\n"))
      ~tmp:(temp_dir ()) ~relay
  in
  (f, result, Buffer.contents said, !published)

let test_sign_relay_shows () =
  let _, result, said, _ = run_relay ~answers:[ "" ] () in
  (match result with Ok () -> () | Error e -> Alcotest.fail e);
  List.iter
    (fun sub ->
      Alcotest.(check bool)
        ("shows " ^ sub ^ "\n" ^ said)
        true (contains ~sub said))
    [
      "No node version is waiting for signatures.";
      "Digestif relay 0.3.0, waiting for signatures on o/r";
      "Reading which of the 3 commit(s) since relay-v0.2.0 touch the relay";
      "def456";
      "actions/runs/9";
      "1 commit(s) touching the relay since relay-v0.2.0";
      "- Report the relay version";
      "https://github.com/o/r/compare/relay-v0.2.0...relay-v0.3.0";
      "Report the version.";
      "0003_relay_version.sql";
      "(the tag's file matches)";
      "    | ALTER TABLE circle ADD COLUMN relay_version TEXT;";
      doc_030.bundle.bundle_sha256;
      "(the draft's file matches)";
      "Compatible with relays from 0.2.0 on.";
      "https://dinners.digestif.io  0.2.0";
      "https://dinners-roman.example  no relay_version";
      "Nobody has signed it yet.";
      "Left waiting; nothing was signed.";
    ];
  Alcotest.(check bool)
    "a test-only commit is not shown" false
    (contains ~sub:"A relay test only" said);
  Alcotest.(check bool)
    "a node-only commit is not shown" false
    (contains ~sub:"A node change" said);
  Alcotest.(check bool)
    "migrations 0.2.0 had are not shown" false
    (contains ~sub:"0001_init.sql" said)

let test_sign_relay_signs_and_waits () =
  let f, result, said, published = run_relay () in
  (match result with Ok () -> () | Error e -> Alcotest.fail e);
  Alcotest.(check int) "nothing published" 0 (List.length published);
  Alcotest.(check bool)
    ("waits for Roman: " ^ said)
    true
    (contains ~sub:"relay-v0.3.0 waits for Roman." said);
  match !(f.r_uploaded) with
  | None -> Alcotest.fail "nothing was uploaded"
  | Some path -> (
      match
        Release.signatures_of_string
          (In_channel.with_open_bin path In_channel.input_all)
      with
      | Error e -> Alcotest.fail e
      | Ok sigs ->
          Alcotest.(check (list string))
            "signed over the relay domain"
            [ Keys.public mike ]
            (Release.valid_signers ~domain:Release.relay_release_domain
               bytes_030 sigs);
          Alcotest.(check (list string))
            "never over the node domain" []
            (Release.valid_signers ~domain:Release.release_domain bytes_030 sigs)
      )

let test_sign_relay_completes_and_publishes () =
  let _, result, said, published = run_relay ~signed_by:[ (54, roman) ] () in
  (match result with Ok () -> () | Error e -> Alcotest.fail e);
  Alcotest.(check bool)
    ("names Roman: " ^ said) true
    (contains ~sub:"Already signed by: Roman" said);
  Alcotest.(check bool)
    ("says the second signature publishes it: " ^ said)
    true
    (contains ~sub:"One more signature publishes it." said);
  Alcotest.(check (list string))
    "publishes 0.3.0" [ "0.3.0" ]
    (List.map Version.to_string published)

let test_sign_relay_outsider () =
  let f, result, _, published = run_relay ~key:mallory () in
  Alcotest.(check bool) "refused" true (Result.is_error result);
  Alcotest.(check bool) "nothing uploaded" true (!(f.r_uploaded) = None);
  Alcotest.(check int) "nothing published" 0 (List.length published)

let test_sign_both_lines () =
  let _, result, said, _ = run_relay ~node_draft:true ~answers:[ ""; "" ] () in
  (match result with Ok () -> () | Error e -> Alcotest.fail e);
  Alcotest.(check bool)
    "the node line first" true
    (contains ~sub:"Digestif 0.2.1" said
    && contains ~sub:"Digestif relay 0.3.0" said);
  Alcotest.(check bool)
    "a relay tag is never a node version" true
    (List.for_all
       (fun (r : Sign_next.draft) -> r.tag <> "relay-v0.3.0")
       (Result.get_ok
          (Sign_next.releases_of_string (relay_listing ~signed_by:[] ()))))

(* A draft on a line this digestif-update does not know is named, never passed over: the relay line
   was once such a line, and a signer running an older digestif-update saw nothing of it
   (ISS-47279). *)
let test_sign_unread_draft () =
  let listing =
    {|[{"tag_name":"frob-v1.0.0","draft":true,"assets":[]},
       {"tag_name":"v0.2.0","draft":false,"assets":[]}]|}
  in
  Alcotest.(check (list string))
    "the relay and node lines are read" []
    (Result.get_ok
       (Sign_next.unread_drafts
          (relay_listing ~node_draft:true ~signed_by:[] ())));
  let gh = function
    | [ "api"; "repos/o/r/releases?per_page=50" ] -> Ok listing
    | args -> Error ("unexpected gh " ^ String.concat " " args)
  in
  match
    Sign_next.run ~gh ~signers:founders
      ~config:{ Sign_next.key_command = "unused"; repo = "o/r" }
      ~read_key:(fun () -> Alcotest.fail "read a key with nothing to sign")
      ~ask:(fun _ -> Alcotest.fail "asked with nothing to sign")
      ~say:ignore ~tmp:(temp_dir ()) ~relay:Sign_next.no_relay
  with
  | Ok () -> Alcotest.fail "an unread draft passed in silence"
  | Error e ->
      Alcotest.(check bool)
        ("names the draft: " ^ e) true
        (contains ~sub:"frob-v1.0.0" e
        && contains ~sub:"newest node release that is not a draft" e)

let test_relay_paths () =
  let specs =
    Sign_next.pathspecs_of_string
      "# c\n\
       relay/src\n\
       conformance/src/fold.ts\n\
       :(exclude,glob)relay/**/*.test.ts\n\
       :(glob)ui/**/x.ts\n\
       :!relay/src/skip\n"
  in
  List.iter
    (fun (path, want) ->
      Alcotest.(check bool) path want (Sign_next.in_paths specs path))
    [
      ("relay/src/read.ts", true);
      ("relay/src/a/b.ts", true);
      ("relay/srcx/read.ts", false);
      ("relay/src/read.test.ts", false);
      ("relay/src/deep/read.test.ts", false);
      ("conformance/src/fold.ts", true);
      ("conformance/src/keys.ts", false);
      ("ui/x.ts", true);
      ("ui/a/b/x.ts", true);
      ("ui/ax.ts", false);
      ("relay/src/skip/y.ts", false);
    ]

let publish_env ?(signed_by = [ (53, mike); (54, roman) ]) ?(draft = true) ~dir
    ~announced () =
  let f, gh = relay_gh ~draft ~signed_by () in
  let said = Buffer.create 256 in
  let env : Relay_publish.env =
    {
      gh;
      repo = "o/r";
      signers = founders;
      channel =
        (fun ~message:_ write ->
          let before =
            Sys.file_exists (Filename.concat dir "relay/0.3.0/manifest.json")
          in
          Result.map (fun () -> not before) (write dir));
      announce = (fun _ -> Ok announced);
      say = (fun l -> Buffer.add_string said (l ^ "\n"));
    }
  in
  (f, env, said)

let test_relay_publish () =
  let dir = temp_dir () in
  Out_channel.with_open_bin (Filename.concat dir "index.json") (fun oc ->
      output_string oc
        {|{"format":"digestif-feed-v0","releases":[],"revocations":[{"document":"revocations/a.json","signatures":"revocations/a.sig.json"}]}|});
  let held = Relay_publish.Held "Not announced: one line." in
  let f, env, said = publish_env ~dir ~announced:held () in
  (match Relay_publish.run env ~version:(v "0.3.0") with
  | Ok (Relay_publish.Held _) -> ()
  | Ok _ -> Alcotest.fail "the stub's answer was not returned"
  | Error e -> Alcotest.fail (Relay_publish.error_to_string e));
  Alcotest.(check bool)
    "published, never Latest" true
    (List.mem
       [
         "release";
         "edit";
         "relay-v0.3.0";
         "--repo";
         "o/r";
         "--draft=false";
         "--latest=false";
       ]
       !(f.r_calls));
  let read p =
    In_channel.with_open_bin (Filename.concat dir p) In_channel.input_all
  in
  Alcotest.(check string)
    "the manifest's exact bytes" bytes_030
    (read "relay/0.3.0/manifest.json");
  (match
     Release.signatures_of_string (read "relay/0.3.0/manifest.sig.json")
   with
  | Ok sigs ->
      Alcotest.(check int)
        "both signatures" 2
        (List.length
           (Release.valid_signers ~domain:Release.relay_release_domain bytes_030
              sigs))
  | Error e -> Alcotest.fail e);
  let index = Yojson.Safe.from_string (read "relay/index.json") in
  Alcotest.(check string)
    "the relay feed"
    {|{"format":"digestif-relay-feed-v0","releases":[{"version":"0.3.0","manifest":"0.3.0/manifest.json","signatures":"0.3.0/manifest.sig.json"}],"revocations":[{"document":"../revocations/a.json","signatures":"../revocations/a.sig.json"}]}|}
    (Yojson.Safe.to_string index);
  Alcotest.(check bool)
    ("says the held line: " ^ Buffer.contents said)
    true
    (contains ~sub:"Not announced: one line." (Buffer.contents said));
  (* Run again: nothing changes on the channel, and it still answers. *)
  let _, env, said =
    publish_env ~draft:false ~dir ~announced:(Relay_publish.Posted "h") ()
  in
  (match Relay_publish.run env ~version:(v "0.3.0") with
  | Ok (Relay_publish.Posted "h") -> ()
  | _ -> Alcotest.fail "a second run did not finish");
  Alcotest.(check bool)
    "says the channel holds it" true
    (contains ~sub:"The channel already holds relay/0.3.0/"
       (Buffer.contents said))

let test_relay_publish_waits () =
  let dir = temp_dir () in
  let f, env, _ =
    publish_env
      ~signed_by:[ (53, mike) ]
      ~dir ~announced:(Relay_publish.Posted "h") ()
  in
  (match Relay_publish.run env ~version:(v "0.3.0") with
  | Error (Relay_publish.Waiting e) ->
      Alcotest.(check bool) ("names Roman: " ^ e) true (contains ~sub:"Roman" e)
  | _ -> Alcotest.fail "published with one signature");
  Alcotest.(check bool)
    "the release is not edited" false
    (List.exists (fun c -> List.mem "edit" c) !(f.r_calls));
  Alcotest.(check bool)
    "nothing on the channel" false
    (Sys.file_exists (Filename.concat dir "relay"))

let test_relay_publish_other_manifest () =
  let dir = temp_dir () in
  Sys.mkdir (Filename.concat dir "relay") 0o755;
  Sys.mkdir (Filename.concat dir "relay/0.3.0") 0o755;
  Out_channel.with_open_bin (Filename.concat dir "relay/0.3.0/manifest.json")
    (fun oc -> output_string oc "{}");
  let _, env, _ = publish_env ~dir ~announced:(Relay_publish.Posted "h") () in
  match Relay_publish.run env ~version:(v "0.3.0") with
  | Error (Relay_publish.Failed e) ->
      Alcotest.(check bool) e true (contains ~sub:"a different manifest" e)
  | _ -> Alcotest.fail "overwrote another manifest"

let test_relay_held_line () =
  let one l = not (String.contains l '\n') in
  (match
     Relay_publish.held_line ~version:(v "0.1.0")
       [
         ("https://a.example", Ok None); ("https://b.example", Ok (Some "0.1.0"));
       ]
   with
  | Some l ->
      Alcotest.(check bool) ("one line: " ^ l) true (one l);
      List.iter
        (fun sub ->
          Alcotest.(check bool) (sub ^ " in " ^ l) true (contains ~sub l))
        [
          "https://a.example does not know relay_release yet";
          "ci/release.sh relay-publish --version 0.1.0 again";
          "step 6";
        ]
  | None -> Alcotest.fail "an old relay was not held");
  (match
     Relay_publish.held_line ~version:(v "0.1.0")
       [ ("https://a.example", Ok None); ("https://b.example", Ok None) ]
   with
  | Some l ->
      Alcotest.(check bool)
        l true
        (contains ~sub:"https://a.example and https://b.example do not know" l
        && one l)
  | None -> Alcotest.fail "two old relays were not held");
  (match
     Relay_publish.held_line ~version:(v "0.1.0")
       [ ("https://a.example", Error "timed out") ]
   with
  | Some l ->
      Alcotest.(check bool) l true (contains ~sub:"could not be read" l && one l)
  | None -> Alcotest.fail "an unread relay was not held");
  Alcotest.(check (option string))
    "every relay reports a version" None
    (Relay_publish.held_line ~version:(v "0.1.0")
       [
         ("https://a.example", Ok (Some "0.1.0"));
         ("https://b.example", Ok (Some "0.0.9"));
       ])

let test_relay_version_of_circle () =
  Alcotest.(check (option string))
    "read" (Some "0.1.0")
    (Relay_publish.relay_version_of_circle
       (Yojson.Safe.from_string {|{"root":"x","relay_version":"0.1.0"}|}));
  Alcotest.(check (option string))
    "absent" None
    (Relay_publish.relay_version_of_circle
       (Yojson.Safe.from_string {|{"root":"x"}|}))

let draft tag d signed =
  let version = v (String.sub tag 1 (String.length tag - 1)) in
  {
    Sign_next.tag;
    version;
    draft = d;
    assets =
      (if signed then
         [
           {
             Sign_next.id = 1;
             name = Sign_next.signature_asset_name (Keys.public mike);
             digest = None;
           };
         ]
       else []);
  }

(* Two node versions waiting at once, v0.2.2 and v0.2.1, against a fake gh (digestif#265). *)
let run_two answers =
  let asset id name = `Assoc [ ("id", `Int id); ("name", `String name) ] in
  let release tag draft assets =
    `Assoc
      [
        ("tag_name", `String tag);
        ("draft", `Bool draft);
        ("assets", `List assets);
      ]
  in
  let listed =
    Yojson.Safe.to_string
      (`List
         [
           release "v0.2.2" true [ asset 22 "manifest.json" ];
           release "v0.2.1" true [ asset 21 "manifest.json" ];
           release "v0.2.0" false [ asset 11 "manifest.json" ];
           release "v0.1.9" true [ asset 19 "manifest.json" ];
         ])
  in
  let uploaded = ref [] and asked = ref 0 and keys = ref 0 in
  let gh args =
    match args with
    | [ "api"; "repos/o/r/releases?per_page=50" ] -> Ok listed
    | [ "api"; "-H"; _; "repos/o/r/releases/assets/21" ] ->
        Ok (manifest_json "0.2.1")
    | [ "api"; "-H"; _; "repos/o/r/releases/assets/22" ] ->
        Ok (manifest_json "0.2.2")
    | [ "api"; c; "--jq"; ".sha" ] when contains ~sub:"commits/v0.2" c ->
        Ok "abc123\n"
    | "api" :: run :: _ when contains ~sub:"actions/workflows" run ->
        Ok "https://github.com/o/r/actions/runs/7\n"
    | [ "api"; c; "--jq"; _ ] when contains ~sub:"compare/" c ->
        Ok "Fix the digest\n"
    | [ "release"; "upload"; tag; _; "--repo"; "o/r"; "--clobber" ] ->
        uploaded := !uploaded @ [ tag ];
        Ok ""
    | _ -> Error ("unexpected gh " ^ String.concat " " args)
  in
  let said = Buffer.create 256 in
  let answers = ref answers in
  let result =
    Sign_next.run ~gh ~signers:founders
      ~config:{ Sign_next.key_command = "unused"; repo = "o/r" }
      ~read_key:(fun () ->
        incr keys;
        Ok (Keys.encode_secret mike ^ "\n"))
      ~ask:(fun _ ->
        incr asked;
        match !answers with
        | a :: rest ->
            answers := rest;
            a
        | [] -> "")
      ~say:(fun l -> Buffer.add_string said (l ^ "\n"))
      ~tmp:(temp_dir ()) ~relay:Sign_next.no_relay
  in
  (match result with Ok () -> () | Error e -> Alcotest.fail e);
  (!uploaded, !asked, !keys, Buffer.contents said)

let test_sign_next_signs_every_waiting_version () =
  let uploaded, asked, keys, said = run_two [ "s" ] in
  Alcotest.(check (list string))
    "one s signs every waiting version, newest first" [ "v0.2.2"; "v0.2.1" ]
    uploaded;
  Alcotest.(check int) "asked once" 1 asked;
  Alcotest.(check int) "the key is read once" 1 keys;
  Alcotest.(check bool)
    ("the newest in full: " ^ said)
    true
    (contains ~sub:"Digestif 0.2.2" said);
  Alcotest.(check bool)
    ("an older one in a line: " ^ said)
    true
    (contains ~sub:"also v0.2.1: nobody has signed it" said);
  Alcotest.(check bool)
    ("one question for both: " ^ said)
    true
    (contains ~sub:"s signs all 2 versions" (Sign_next.question ~count:2));
  Alcotest.(check bool)
    "a draft older than the published version is not offered" false
    (contains ~sub:"0.1.9" said);
  let uploaded, asked, keys, _ = run_two [ "" ] in
  Alcotest.(check (list string)) "anything else signs nothing" [] uploaded;
  Alcotest.(check int) "still one question" 1 asked;
  Alcotest.(check int) "and no key read" 0 keys

let test_sign_next_waiting () =
  let tags l =
    List.map (fun (r : Sign_next.draft) -> r.tag) (Sign_next.waiting_all l)
  in
  Alcotest.(check (list string))
    "every draft newer than the newest published version, newest first"
    [ "v0.3.2"; "v0.3.1" ]
    (tags
       [
         draft "v0.3.0" false false;
         draft "v0.2.9" true false;
         draft "v0.3.1" true true;
         draft "v0.3.2" true false;
       ]);
  Alcotest.(check (list string))
    "nothing published yet: every draft" [ "v0.3.1"; "v0.3.0" ]
    (tags [ draft "v0.3.0" true false; draft "v0.3.1" true false ]);
  Alcotest.(check (list string))
    "no draft, nothing waits" []
    (tags [ draft "v0.3.0" false false ])

let test_signer_config () =
  let dir = temp_dir () in
  let path = Filename.concat dir "signer.json" in
  (match Sign_next.load_config path with
  | Ok _ -> Alcotest.fail "a missing signer.json loaded"
  | Error e ->
      Alcotest.(check bool) ("names the file: " ^ e) true (contains ~sub:path e);
      Alcotest.(check bool)
        ("shows what to write: " ^ e)
        true
        (contains ~sub:"key_command" e));
  Out_channel.with_open_bin path (fun oc ->
      Out_channel.output_string oc {|{ "key_command": "op read op://x/y" }|});
  (match Sign_next.load_config path with
  | Ok c ->
      Alcotest.(check string)
        "the default repository" "digestif-ai/digestif" c.repo
  | Error e -> Alcotest.fail e);
  Alcotest.(check bool)
    "an empty command is refused" true
    (Result.is_error (Sign_next.config_of_string {|{ "key_command": " " }|}))

(* Where sign --next reads the key: signer.json's command when the file exists, else the hidden
   prompt a terminal offers, else an error saying what to write. *)
let test_key_reader () =
  let dir = temp_dir () in
  let path = Filename.concat dir "signer.json" in
  let pasted () = Ok "pasted" in
  (match Sign_next.key_reader ~path ~prompt:(Some pasted) with
  | Ok (c, read) ->
      Alcotest.(check string)
        "no signer.json: the default repository" "digestif-ai/digestif" c.repo;
      Alcotest.(check (result string string))
        "no signer.json: the prompt" (Ok "pasted") (read ())
  | Error e -> Alcotest.fail e);
  (match Sign_next.key_reader ~path ~prompt:None with
  | Ok _ -> Alcotest.fail "no signer.json and no terminal read a key"
  | Error e ->
      Alcotest.(check bool)
        ("says what to write: " ^ e)
        true
        (contains ~sub:"key_command" e));
  let key = Filename.concat dir "downloaded.key" in
  Out_channel.with_open_bin key (fun oc ->
      Out_channel.output_string oc "from-file\n");
  Out_channel.with_open_bin path (fun oc ->
      Out_channel.output_string oc
        (Yojson.Safe.to_string
           (`Assoc [ ("key_command", `String ("cat " ^ Filename.quote key)) ])));
  match Sign_next.key_reader ~path ~prompt:(Some pasted) with
  | Ok (_, read) ->
      Alcotest.(check (result string string))
        "signer.json wins over the prompt" (Ok "from-file\n") (read ())
  | Error e -> Alcotest.fail e

let test_bundle_carries_update_binary () =
  let dir = temp_dir () in
  let put rel contents =
    let path = Filename.concat dir rel in
    ignore (Sys.command ("mkdir -p " ^ Filename.quote (Filename.dirname path)));
    Out_channel.with_open_bin path (fun oc ->
        Out_channel.output_string oc contents)
  in
  put "digestif" "node";
  put "digestif-update" "signer";
  put "behaviors/bin/nightly-hook" "#!/bin/sh\n";
  let out = Filename.concat dir "a.tar.gz" in
  (match
     Bundle.write
       ~update_binary:(Filename.concat dir "digestif-update")
       ~binary:(Filename.concat dir "digestif")
       ~behaviors:(Filename.concat dir "behaviors")
       ~out ()
   with
  | Ok () -> ()
  | Error e -> Alcotest.fail e);
  let listing = Filename.concat dir "listing" in
  ignore
    (Sys.command
       (Printf.sprintf "tar -tzf %s > %s" (Filename.quote out)
          (Filename.quote listing)));
  Alcotest.(check bool)
    "bin/digestif-update is in the archive" true
    (List.mem "bin/digestif-update"
       (In_channel.with_open_bin listing In_channel.input_lines))

let () =
  let t name f = Alcotest.test_case name `Quick f in
  Ci_alcotest.run "digestif-update"
    [
      ("encoding", [ t "base64url" test_b64url; t "versions" test_version ]);
      ( "both signers",
        [
          t "no signers" test_no_signers;
          t "one configured signer" test_one_configured_signer;
          t "both signed" test_both_signed;
          t "one signer" test_one_signer;
          t "outsider" test_outsider_does_not_count;
          t "other bytes" test_signature_over_other_bytes;
          t "newest" test_newest;
          t "no rollback" test_no_rollback;
          t "duplicate version" test_duplicate_version;
        ] );
      ( "shipped platforms",
        [
          t "parses" test_shipped_parses;
          t "all named" test_shipped_all_named;
          t "missing one" test_shipped_missing_one;
          t "unknown and twice" test_shipped_unknown_and_twice;
        ] );
      ("pinning", [ t "pin" test_pin; t "pin unsigned" test_pin_unsigned ]);
      ( "signer set",
        [
          t "change" test_signer_change;
          t "old set after change" test_old_set_after_change;
          t "needs both current" test_change_needs_both_current;
          t "needs new keys" test_change_needs_new_keys;
          t "set of one" test_change_to_one_signer;
          t "past a pin" test_change_past_pin;
        ] );
      ( "revocation",
        [
          t "halts" test_revocation_halts;
          t "then new set" test_revocation_then_new_set;
          t "never returns" test_revoked_key_never_returns;
          t "outsider ignored" test_outsider_revocation_ignored;
        ] );
      ( "circle revocation",
        [
          t "body roundtrip" test_circle_body_roundtrip;
          t "malformed" test_circle_malformed;
          t "persists and halts" test_circle_revocation_persists_and_halts;
          t "outsider ignored" test_circle_revocation_outsider;
        ] );
      ( "recall",
        [
          t "a recalled version never installs" test_recalled_never_installs;
          t "only current keys count" test_recall_counts_only_current_keys;
          t "moves back" test_recall_moves_back;
          t "a week's limit" test_recall_week_limit;
          t "chained recalls stop at the floor"
            test_chained_recalls_stop_at_the_floor;
          t "nothing older" test_recall_nothing_older;
          t "a failed self-test stays" test_recall_failed_self_test;
          t "the channel write" test_recall_channel_write;
          t "with no --key, the key signer.json names"
            test_recall_reads_signer_json;
          t "the update pass obeys it" test_update_pass_obeys_recall;
          t "a newer release beats it" test_newer_release_beats_recall;
          t "the circle starts a pass" test_circle_recall_starts_a_pass;
          t "a healthy switch records its first install"
            test_promote_records_first_install;
        ] );
      ( "install",
        [
          t "end to end" test_end_to_end;
          t "unsupervised stages only" test_unsupervised_stages_only;
          t "tampered artifact" test_tampered_artifact;
          t "interrupted download leaves current" test_interrupted_download;
          t "failed self-test never switches"
            test_failed_self_test_never_switches;
          t "the runtime is the release's own" test_runtime_is_the_releases;
          t "a runtime that does not run is refused"
            test_runtime_that_does_not_run_is_refused;
          t "an archive without its runtime is refused"
            test_archive_without_runtime_is_refused;
          t "a checkout's release uses the node on PATH"
            test_local_release_uses_path_node;
          t "installed counts the good release"
            test_installed_counts_good_release;
          t "the good release never lowers installed"
            test_good_release_never_lowers_installed;
          t "service install finds the staged release"
            test_holding_finds_staged_release;
          t "a local release keeps the good release's behaviors"
            test_local_release_keeps_good_behaviors;
          t "a local release with no behaviors is refused"
            test_local_release_without_behaviors_is_refused;
          t "a local release without its web UI is refused"
            test_local_release_without_web_ui_is_refused;
          t "service install skips a release without its web UI"
            test_holding_skips_release_without_web_ui;
          t "the web UI check reads web/embed's page"
            test_web_ui_marker_is_the_placeholder;
          t "a local release with other behaviors is restaged"
            test_local_release_restages_other_behaviors;
          t "state roundtrip" test_state_roundtrip;
          t "trust root" test_trust_root_parses;
          t "signer set reaches the build's" test_signer_set_reaches_build;
          t "a signed shrink of the signer set holds"
            test_signer_set_shrink_holds;
          t "sign names a key file it cannot read" test_sign_missing_key;
          t "verify both signed" test_verify_both;
          t "verify one missing" test_verify_one_missing;
          t "verify drops other signatures" test_verify_drops_others;
          t "verify refuses another version" test_verify_wrong_version;
          t "shipped build names two" test_shipped_build_names_two;
          t "hook follows current" test_hook_follows_current;
          t "status problems" test_status_problems;
        ] );
      ( "relay release",
        [
          t "the manifest round-trips" test_relay_manifest_roundtrip;
          t "the manifest refuses" test_relay_manifest_refusals;
          t "its own domain line" test_relay_domain_line;
          t "every current signer" test_relay_fold_counts_every_signer;
          t "a revoked key halts it" test_relay_fold_halts_on_revoked_key;
          t "ordered by version" test_relay_fold_orders_by_version;
          t "two documents under one version" test_relay_fold_conflict;
          t "an unreadable document" test_relay_fold_unreadable;
          t "relay-manifest, sign and verify" test_relay_manifest_cli;
        ] );
      ( "sign --next",
        [
          t "signs" test_sign_next_signs;
          t "drops" test_sign_next_drops;
          t "leaves" test_sign_next_leaves;
          t "outsider key" test_sign_next_outsider_key;
          t "wrong version" test_sign_next_wrong_version;
          t "shows who signed" test_sign_next_shows_who_signed;
          t "waiting" test_sign_next_waiting;
          t "signs every waiting version"
            test_sign_next_signs_every_waiting_version;
          t "relay: shows" test_sign_relay_shows;
          t "relay: signs and waits" test_sign_relay_signs_and_waits;
          t "relay: completes and publishes"
            test_sign_relay_completes_and_publishes;
          t "relay: outsider" test_sign_relay_outsider;
          t "both lines" test_sign_both_lines;
          t "a draft on an unknown line" test_sign_unread_draft;
          t "relay paths" test_relay_paths;
          t "relay-publish" test_relay_publish;
          t "relay-publish waits" test_relay_publish_waits;
          t "relay-publish other manifest" test_relay_publish_other_manifest;
          t "relay-publish held line" test_relay_held_line;
          t "relay version of circle" test_relay_version_of_circle;
          t "signer.json" test_signer_config;
          t "where the key is read" test_key_reader;
          t "archive carries digestif-update" test_bundle_carries_update_binary;
        ] );
      ( "supervisor",
        [
          t "awake clock" test_awake_clock;
          t "crash on start rolls back" test_crash_on_start_rolls_back;
          t "healthy is kept" test_healthy_is_kept;
          t "unhealthy times out" test_unhealthy_times_out;
          t "sleep does not roll back" test_sleep_does_not_roll_back;
          t "trial starts are bounded" test_trial_starts_are_bounded;
          t "whole loop" test_supervisor_loop;
          t "a crashing version goes back" test_crashing_version_goes_back;
          t "spread crashes stay" test_spread_crashes_stay;
          t "crash with nothing older" test_crash_nothing_older;
          t "crash whose older release fails its self-test"
            test_crash_older_self_test_fails;
          t "crash count follows the release"
            test_crash_count_follows_the_release;
          t "stop is not a crash" test_stop_is_not_a_crash;
        ] );
      ( "schedule",
        [
          t "due" test_due;
          t "report once" test_report_once;
          t "switches" test_schedule_switches;
          t "reports refusal" test_schedule_reports_refusal;
          t "report drop keeps later lines" test_report_drop_keeps_later_lines;
          t "reports failure" test_schedule_reports_failure;
        ] );
    ]
