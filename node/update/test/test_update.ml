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

(* A release archive as a signer bundles it: bin/digestif and behaviors/. The fake binary answers
   `self-test` the way the real one does, except 0.3.0, whose self-test fails. *)
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
      let out = root ^ ".tar.gz" in
      let code =
        Sys.command
          (Printf.sprintf "tar -czf %s -C %s bin behaviors" (Filename.quote out)
             (Filename.quote root))
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

let node24 () = Some 24

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

let test_missing_node_is_named () =
  let dir = temp_dir () in
  let feed = Filename.concat dir "feed/" in
  channel feed [ release ~by:[ mike; roman ] "0.2.0" ] ~tamper:false;
  let node = supervised_node () in
  let o = update ~node_major:(fun () -> None) ~feed node in
  (match o.step with
  | Updater.Stage_failed (_, why, _) ->
      Alcotest.(check bool)
        ("names Node.js: " ^ why) true
        (contains ~sub:"Node.js 24" why)
  | _ -> Alcotest.fail "a missing Node.js did not hold the switch");
  Alcotest.(check string) "current untouched" "0.1.0" (current node);
  Alcotest.(check bool)
    "not refused: installing Node.js lets it through" false
    (State.is_refused (loaded (Schedule.state_path node)) (v "0.2.0"))

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
  | Schedule.Switched _, _ ->
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
      ~tmp:(temp_dir ())
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
    (contains ~sub:"Already signed by: Roman" said)

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

let test_sign_next_waiting () =
  let tag = Option.map (fun (r : Sign_next.draft) -> r.tag) in
  Alcotest.(check (option string))
    "the newest draft" (Some "v0.3.1")
    (tag
       (Sign_next.waiting
          [
            draft "v0.3.0" true false;
            draft "v0.3.1" true false;
            draft "v0.4.0" false false;
          ]));
  Alcotest.(check (option string))
    "a signed draft waits past newer ones" (Some "v0.3.0")
    (tag
       (Sign_next.waiting
          [ draft "v0.3.0" true true; draft "v0.3.1" true false ]));
  Alcotest.(check (option string))
    "no draft, nothing waits" None
    (tag (Sign_next.waiting [ draft "v0.3.0" false false ]))

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
  Alcotest.run "digestif-update"
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
      ( "install",
        [
          t "end to end" test_end_to_end;
          t "unsupervised stages only" test_unsupervised_stages_only;
          t "tampered artifact" test_tampered_artifact;
          t "interrupted download leaves current" test_interrupted_download;
          t "failed self-test never switches"
            test_failed_self_test_never_switches;
          t "missing Node.js is named" test_missing_node_is_named;
          t "state roundtrip" test_state_roundtrip;
          t "trust root" test_trust_root_parses;
          t "signer set reaches the build's" test_signer_set_reaches_build;
          t "a signed shrink of the signer set holds"
            test_signer_set_shrink_holds;
          t "sign names a key file it cannot read" test_sign_missing_key;
          t "shipped build names two" test_shipped_build_names_two;
          t "hook follows current" test_hook_follows_current;
          t "status problems" test_status_problems;
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
          t "signer.json" test_signer_config;
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
