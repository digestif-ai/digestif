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
let binary_bytes version = "#!digestif " ^ version ^ "\n"

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
          ("format", `String "digestif-release-v0");
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

let state_with_founders path =
  State.save path
    { State.installed = v "0.1.0"; trust = trust founders; pin = None }

let test_end_to_end () =
  let dir = temp_dir () in
  let feed = Filename.concat dir "feed/" in
  channel feed [ release ~by:[ mike; roman ] "0.2.0" ] ~tamper:false;
  let binary = Filename.concat dir "digestif"
  and state_path = Filename.concat dir "state/update.json" in
  write binary (binary_bytes "0.1.0");
  state_with_founders state_path;
  match
    Updater.run ~fetch:Feed.default_fetch ~base:feed ~platform ~state_path
      ~binary
  with
  | Error e -> Alcotest.fail e
  | Ok o -> (
      Alcotest.(check (option string))
        "installed" (Some "0.2.0")
        (Option.map Version.to_string o.installed);
      Alcotest.(check string)
        "binary replaced" (binary_bytes "0.2.0") (State.read_file binary);
      Alcotest.(check string)
        "previous kept" (binary_bytes "0.1.0")
        (State.read_file (binary ^ ".previous"));
      (match State.load state_path with
      | Ok s ->
          Alcotest.(check string)
            "state records it" "0.2.0"
            (Version.to_string s.installed)
      | Error e -> Alcotest.fail e);
      match
        Updater.run ~fetch:Feed.default_fetch ~base:feed ~platform ~state_path
          ~binary
      with
      | Ok o ->
          Alcotest.(check bool)
            "second pass installs nothing" true (o.installed = None)
      | Error e -> Alcotest.fail e)

let test_tampered_artifact () =
  let dir = temp_dir () in
  let feed = Filename.concat dir "feed/" in
  channel feed [ release ~by:[ mike; roman ] "0.2.0" ] ~tamper:true;
  let binary = Filename.concat dir "digestif"
  and state_path = Filename.concat dir "update.json" in
  write binary (binary_bytes "0.1.0");
  state_with_founders state_path;
  (match
     Updater.run ~fetch:Feed.default_fetch ~base:feed ~platform ~state_path
       ~binary
   with
  | Ok _ -> Alcotest.fail "a tampered artifact installed"
  | Error e ->
      Alcotest.(check bool)
        ("refused: " ^ e) true
        (contains ~sub:"bytes" e || contains ~sub:"hashes" e));
  Alcotest.(check string)
    "binary untouched" (binary_bytes "0.1.0") (State.read_file binary)

let test_state_roundtrip () =
  let s =
    {
      State.installed = v "1.2.3";
      trust = { signers = founders; revoked = [ Keys.public carol ] };
      pin = Some (v "1.2.3");
    }
  in
  match State.of_string (State.to_string s) with
  | Ok s' ->
      Alcotest.(check string)
        "roundtrip" (State.to_string s) (State.to_string s')
  | Error e -> Alcotest.fail e

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

let loaded path =
  match State.load path with Ok s -> s | Error e -> Alcotest.fail e

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

let schedule_config dir feed binary =
  Schedule.config ~base:feed ~platform:(fun () -> Ok platform) ~dir ~binary ()

let test_schedule_installs () =
  let dir = temp_dir () in
  let feed = Filename.concat dir "feed/" in
  channel feed [ release ~by:[ mike; roman ] "0.2.0" ] ~tamper:false;
  let node = Filename.concat dir "node"
  and binary = Filename.concat dir "digestif" in
  write binary (binary_bytes "0.1.0");
  state_with_founders (Schedule.state_path node);
  let cfg = schedule_config node feed binary in
  (match Schedule.tick cfg ~now:1_000. ~woke:false with
  | Some (Schedule.Installed v', _) ->
      Alcotest.(check string) "installed" "0.2.0" (Version.to_string v')
  | _ -> Alcotest.fail "the first tick of a node did not install");
  Alcotest.(check string)
    "binary replaced" (binary_bytes "0.2.0") (State.read_file binary);
  Alcotest.(check bool)
    "not due again within the day" true
    (Schedule.tick cfg ~now:2_000. ~woke:false = None);
  Alcotest.(check (list string))
    "the digest hears of it"
    [ "Updated Digestif to 0.2.0." ]
    (Report.take (Schedule.report_path node));
  Alcotest.(check (list string))
    "and only once" []
    (Report.take (Schedule.report_path node))

let test_schedule_reports_refusal () =
  let dir = temp_dir () in
  let feed = Filename.concat dir "feed/" in
  channel feed [ release ~by:[ mike ] "0.2.0" ] ~tamper:false;
  let node = Filename.concat dir "node"
  and binary = Filename.concat dir "digestif" in
  write binary (binary_bytes "0.1.0");
  state_with_founders (Schedule.state_path node);
  let cfg = schedule_config node feed binary in
  (match Schedule.pass cfg ~now:1. with
  | Schedule.Not_installed, _ -> ()
  | Schedule.Installed _, _ ->
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
  let node = Filename.concat dir "node"
  and binary = Filename.concat dir "digestif" in
  let cfg = schedule_config node (Filename.concat dir "no-such-feed/") binary in
  (match Schedule.pass cfg ~now:1. with
  | Schedule.Not_installed, [ line ] ->
      Alcotest.(check bool)
        ("a failed pass: " ^ line) true
        (contains ~sub:"The update check failed" line)
  | _ -> Alcotest.fail "an unreachable channel did not fail the pass");
  Alcotest.(check bool)
    "and the next pass waits a day" true
    (Schedule.tick cfg ~now:2. ~woke:false = None)

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
          t "tampered artifact" test_tampered_artifact;
          t "state roundtrip" test_state_roundtrip;
          t "trust root" test_trust_root_parses;
        ] );
      ( "schedule",
        [
          t "due" test_due;
          t "report once" test_report_once;
          t "installs" test_schedule_installs;
          t "reports refusal" test_schedule_reports_refusal;
          t "reports failure" test_schedule_reports_failure;
        ] );
    ]
