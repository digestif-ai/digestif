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

let manifest_json ?(artifact = None) version =
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
       [
         ("format", `String "digestif-release-v1");
         ("version", `String version);
         ("published_at", `String "2026-10-29T00:00:00.000Z");
         ("notes", `String "");
         ("artifacts", `List [ a ]);
       ])
  ^ "\n"

let sign_all ~domain secrets bytes =
  List.fold_left
    (fun sigs s -> Release.add_signature ~domain ~secret:s bytes sigs)
    [] secrets

let release ~by version : Release.manifest Release.signed =
  let bytes = manifest_json version in
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

(* Changing the signer set (docs/releases.md): a digestif-signers-v0 every current and every new
   key signed, never a manifest field. *)

let signer_set ?(created_at = "2026-11-14T15:00:00.000Z") ~by signers :
    Release.signer_set Release.signed =
  let bytes =
    Yojson.Safe.pretty_to_string
      (`Assoc
         [
           ("format", `String "digestif-signers-v0");
           ("created_at", `String created_at);
           ("signers", `List (List.map Release.signer_to_json signers));
         ])
  in
  let doc =
    match Release.signer_set_of_string bytes with
    | Ok d -> d
    | Error e -> failwith e
  in
  {
    bytes;
    doc;
    signatures = sign_all ~domain:Release.signer_set_domain by bytes;
  }

let new_set = [ signer "Mike" mike; signer "Carol" carol ]

let adopt ?(revocations = []) ?seen t changes =
  Policy.adopt_sets ?seen t ~revocations changes

let names (t : Policy.trust) =
  List.map (fun (s : Release.signer) -> s.name) t.signers

let refusals (a : Policy.adoption) =
  List.map (fun (_, r) -> Policy.refusal_to_string r) a.refused

let test_signer_change () =
  let a =
    adopt (trust founders) [ signer_set ~by:[ mike; roman; carol ] new_set ]
  in
  Alcotest.(check (list string))
    "trust moved" [ "Mike"; "Carol" ] (names a.adopted_trust);
  check_installs "the new set signs the next release" (Some "0.3.0")
    (plan a.adopted_trust [ release ~by:[ mike; carol ] "0.3.0" ])

let test_old_set_after_change () =
  let a =
    adopt (trust founders) [ signer_set ~by:[ mike; roman; carol ] new_set ]
  in
  check_installs "the old set no longer suffices" None
    (plan a.adopted_trust [ release ~by:[ mike; roman ] "0.3.0" ])

let test_change_needs_both_current () =
  let a = adopt (trust founders) [ signer_set ~by:[ mike; carol ] new_set ] in
  Alcotest.(check (list string))
    "one current signer cannot change the set" [ "Mike"; "Roman" ]
    (names a.adopted_trust);
  Alcotest.(check (list string))
    "names Roman" [ "not signed by Roman" ] (refusals a)

let test_change_needs_new_keys () =
  let a = adopt (trust founders) [ signer_set ~by:[ mike; roman ] new_set ] in
  Alcotest.(check (list string))
    "new keys prove possession" [ "Mike"; "Roman" ] (names a.adopted_trust);
  Alcotest.(check bool)
    "names Carol" true
    (List.exists (contains ~sub:"Carol") (refusals a))

let test_change_to_one_signer () =
  let a =
    adopt (trust founders)
      [ signer_set ~by:[ mike; roman ] [ signer "Mike" mike ] ]
  in
  Alcotest.(check int)
    "a set of one is refused" 2
    (List.length a.adopted_trust.signers);
  Alcotest.(check bool)
    "says why" true
    (List.exists (contains ~sub:"at least two") (refusals a))

(* A node first started by an older build reaches the current set by folding the chain, in
   whatever order the circle or the channel lists it, and never adopts a link twice. *)
let test_chain_in_any_order () =
  let promote =
    signer_set ~by:[ mike; roman; carol ] (founders @ [ signer "Carol" carol ])
  in
  let remove =
    signer_set ~created_at:"2026-11-15T00:00:00.000Z" ~by:[ mike; roman; carol ]
      new_set
  in
  let a = adopt (trust founders) [ remove; promote ] in
  Alcotest.(check (list string))
    "the chain's end" [ "Mike"; "Carol" ] (names a.adopted_trust);
  Alcotest.(check int) "both links adopted" 2 (List.length a.adopted);
  let replay =
    adopt ~seen:[ promote.bytes; remove.bytes ] a.adopted_trust [ promote ]
  in
  Alcotest.(check (list string))
    "a replayed promotion a removal undid is not adopted again"
    [ "Mike"; "Carol" ]
    (names replay.adopted_trust)

let test_manifest_signers_refused () =
  let bytes =
    Yojson.Safe.to_string
      (`Assoc
         [
           ("format", `String "digestif-release-v1");
           ("version", `String "0.2.0");
           ("published_at", `String "2026-10-29T00:00:00.000Z");
           ("artifacts", `List []);
           ("signers", `List (List.map Release.signer_to_json new_set));
         ])
  in
  Alcotest.(check bool)
    "a manifest naming signers does not parse" true
    (Result.is_error (Release.manifest_of_string bytes))

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
  let revocations = [ revocation ~by:[ mike ] roman ] in
  let a =
    adopt ~revocations (trust founders)
      [ signer_set ~by:[ mike; roman; roman2 ] rotated ]
  in
  check_installs "rotation clears the halt" (Some "0.3.0")
    (plan ~revocations a.adopted_trust [ release ~by:[ mike; roman2 ] "0.3.0" ]);
  Alcotest.(check (list string))
    "and lifts it" []
    (List.map
       (fun (s : Release.signer) -> s.name)
       (Policy.halted a.adopted_trust))

let test_revoked_key_never_returns () =
  let a =
    adopt
      ~revocations:[ revocation ~by:[ mike ] roman ]
      (trust founders)
      [
        signer_set ~by:[ mike; roman; carol ]
          (founders @ [ signer "Carol" carol ]);
      ]
  in
  Alcotest.(check int)
    "a set naming a revoked key is refused" 0 (List.length a.adopted);
  Alcotest.(check bool)
    "says why" true
    (List.exists (contains ~sub:"revoked key") (refusals a))

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

(* The commands on PATH (Cli_links): an install's link into releases/ moves to good, a missing
   digestif-update is made, and a member's own file or link is left alone. *)
let readlink_opt p = try Some (Unix.readlink p) with Unix.Unix_error _ -> None

let cli_links ~node ~bin_dir =
  match Cli_links.link ~dir:node ~bin_dir with
  | Ok changes -> changes
  | Error e -> Alcotest.fail e

let test_cli_links_follow_good () =
  let node = supervised_node () in
  let bin_dir = Filename.concat (temp_dir ()) "bin" in
  Unix.mkdir bin_dir 0o755;
  write
    (Filename.concat (Layout.release_dir node "0.1.0") "bin/digestif-update")
    "x";
  let pinned =
    Filename.concat (Layout.release_dir node "0.1.0") "bin/digestif"
  in
  Unix.symlink pinned (Filename.concat bin_dir "digestif");
  let changes = cli_links ~node ~bin_dir in
  let good name = Filename.concat node ("good/bin/" ^ name) in
  Alcotest.(check (option string))
    "an install's link to a release moves to good"
    (Some (good "digestif"))
    (readlink_opt (Filename.concat bin_dir "digestif"));
  Alcotest.(check (option string))
    "a missing digestif-update is made"
    (Some (good "digestif-update"))
    (readlink_opt (Filename.concat bin_dir "digestif-update"));
  Alcotest.(check int) "two changes" 2 (List.length changes);
  Alcotest.(check int)
    "a second run changes nothing" 0
    (List.length (cli_links ~node ~bin_dir));
  (* digestif-update resolves through good to the release good names. *)
  Alcotest.(check string)
    "the link reaches good's binary"
    (Unix.realpath
       (Filename.concat (Layout.release_dir node "0.1.0") "bin/digestif-update"))
    (Unix.realpath (Filename.concat bin_dir "digestif-update"))

let test_cli_links_leave_the_members_own () =
  let node = supervised_node () in
  let bin_dir = Filename.concat (temp_dir ()) "bin" in
  Unix.mkdir bin_dir 0o755;
  write (Filename.concat bin_dir "digestif") "a binary install.sh copied";
  Unix.symlink "/opt/elsewhere/digestif-update"
    (Filename.concat bin_dir "digestif-update");
  Alcotest.(check int)
    "nothing changes" 0
    (List.length (cli_links ~node ~bin_dir));
  Alcotest.(check string)
    "the copied binary stays" "a binary install.sh copied"
    (State.read_file (Filename.concat bin_dir "digestif"));
  Alcotest.(check (option string))
    "the member's link stays" (Some "/opt/elsewhere/digestif-update")
    (readlink_opt (Filename.concat bin_dir "digestif-update"))

(* Runs [f] with HOME and XDG_DATA_HOME naming [home], restoring both after. *)
let with_home home f =
  let saved =
    List.map (fun k -> (k, Sys.getenv_opt k)) [ "HOME"; "XDG_DATA_HOME" ]
  in
  Unix.putenv "HOME" home;
  Unix.putenv "XDG_DATA_HOME" (Filename.concat home ".local/share");
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun (k, v) -> Unix.putenv k (Option.value v ~default:"")) saved)
    f

(* The commands on PATH are the standard node's: link_default moves them for the node at the
   standard data directory and leaves them alone for any other one. DIG-264 *)
let test_cli_links_are_the_standard_nodes () =
  let pinned node =
    Filename.concat (Layout.release_dir node "0.1.0") "bin/digestif"
  in
  let setup () =
    let home = temp_dir () in
    let bin_dir = Filename.concat home ".local/bin" in
    Digestif_core.Node.mkdir_p bin_dir;
    (home, bin_dir)
  in
  (* A second node: its own data directory, nowhere near the standard one. *)
  let home, bin_dir = setup () in
  let second = supervised_node () in
  Unix.symlink (pinned second) (Filename.concat bin_dir "digestif");
  with_home home (fun () -> Cli_links.link_default ~dir:second ());
  Alcotest.(check (option string))
    "a second node leaves the link alone"
    (Some (pinned second))
    (readlink_opt (Filename.concat bin_dir "digestif"));
  Alcotest.(check (option string))
    "and makes no digestif-update" None
    (readlink_opt (Filename.concat bin_dir "digestif-update"));
  (* The standard node, reached through a link at the standard place. *)
  let home, bin_dir = setup () in
  let first = Unix.realpath (supervised_node ()) in
  Unix.symlink (pinned first) (Filename.concat bin_dir "digestif");
  with_home home (fun () ->
      let standard = Digestif_core.Node.standard_dir () in
      Digestif_core.Node.mkdir_p (Filename.dirname standard);
      Unix.symlink first standard;
      Cli_links.link_default ~dir:standard ());
  Alcotest.(check bool)
    "the standard node moves it to good" true
    (match readlink_opt (Filename.concat bin_dir "digestif") with
    | Some t ->
        Filename.basename (Filename.dirname (Filename.dirname t)) = "good"
    | None -> false)

let test_cli_links_wait_for_good () =
  let node = temp_dir () in
  let bin_dir = Filename.concat (temp_dir ()) "bin" in
  Unix.mkdir bin_dir 0o755;
  Alcotest.(check int)
    "no good, no links" 0
    (List.length (cli_links ~node ~bin_dir));
  Alcotest.(check bool)
    "no digestif-update" false
    (Sys.file_exists (Filename.concat bin_dir "digestif-update"));
  let node = supervised_node () in
  Alcotest.(check int)
    "good's release has no digestif-update, no link to one" 0
    (List.length (cli_links ~node ~bin_dir));
  write
    (Filename.concat (Layout.release_dir node "0.1.0") "bin/digestif-update")
    "x";
  let missing = Filename.concat (temp_dir ()) "no-bin" in
  Alcotest.(check int)
    "no ~/.local/bin, nothing made" 0
    (List.length (cli_links ~node ~bin_dir:missing));
  Alcotest.(check bool)
    "the directory is not made" false (Sys.file_exists missing)

(* An automatic update: the supervisor that was running promotes the new release and keeps its
   child, so only the new release's own repeated step (each pass of digestif run) can link what
   the old good lacked. The install's pinned link moves on the first pass, digestif-update on the
   first pass after the release carrying it becomes good. ISS-74348 *)
let test_cli_links_after_an_update () =
  let node = supervised_node () in
  let bin_dir = Filename.concat (temp_dir ()) "bin" in
  Unix.mkdir bin_dir 0o755;
  Unix.symlink
    (Filename.concat (Layout.release_dir node "0.1.0") "bin/digestif")
    (Filename.concat bin_dir "digestif");
  let next = Layout.release_dir node "0.2.0" in
  write (Layout.binary_in next) (script "0.2.0");
  write (Filename.concat next "bin/digestif-update") "x";
  Layout.point_current node "0.2.0";
  Alcotest.(check int)
    "on trial: the pinned link moves to good, and the old good has no \
     digestif-update"
    1
    (List.length (cli_links ~node ~bin_dir));
  Alcotest.(check bool)
    "no digestif-update yet" false
    (Sys.file_exists (Filename.concat bin_dir "digestif-update"));
  Layout.point_good node "0.2.0";
  Alcotest.(check int)
    "the pass after promotion makes digestif-update" 1
    (List.length (cli_links ~node ~bin_dir));
  Alcotest.(check string)
    "it reaches the promoted release's binary"
    (Unix.realpath (Filename.concat next "bin/digestif-update"))
    (Unix.realpath (Filename.concat bin_dir "digestif-update"));
  Alcotest.(check int)
    "later passes change nothing" 0
    (List.length (cli_links ~node ~bin_dir))

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
  let fetch ~limit target =
    if contains ~sub:"artifacts/" target then
      match !broken with
      | `Fail -> Error (target ^ ": curl exited 56")
      | `Short ->
          Result.map
            (fun b -> String.sub b 0 (String.length b / 2))
            (Feed.default_fetch ~limit target)
      | `Ok -> Feed.default_fetch ~limit target
    else Feed.default_fetch ~limit target
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
  | Error (Stage.Suspect why) -> Alcotest.failf "suspected: %s" why
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
  | Error (Stage.Retry e | Stage.Suspect e | Stage.Refuse e) ->
      Alcotest.failf "not staged: %s" e
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
  | Error (Stage.Retry e | Stage.Suspect e) -> Alcotest.failf "retried: %s" e
  | Ok name -> Alcotest.failf "staged %s without behaviors" name);
  let empty = Filename.concat (temp_dir ()) "behaviors" in
  Unix.mkdir empty 0o755;
  match stage_local ~behaviors:empty node binary with
  | Error (Stage.Refuse why) ->
      Alcotest.(check bool)
        ("names prompts/: " ^ why) true
        (contains ~sub:"prompts/" why)
  | Error (Stage.Retry e | Stage.Suspect e) -> Alcotest.failf "retried: %s" e
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
  | Error (Stage.Retry e | Stage.Suspect e) -> Alcotest.failf "retried: %s" e
  | Ok name -> Alcotest.failf "staged %s without its web UI" name);
  let behaviors = Filename.concat (temp_dir ()) "behaviors" in
  write (Filename.concat behaviors "prompts/always-on.md") "rule";
  match stage_local ~behaviors node binary with
  | Error (Stage.Refuse _) -> ()
  | Error (Stage.Retry e | Stage.Suspect e) -> Alcotest.failf "retried: %s" e
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
    | Error (Stage.Retry e | Stage.Suspect e | Stage.Refuse e) ->
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
            strikes = 0;
            due_at = 5.;
          };
      first_installed = [ (v "1.2.3", 7.) ];
      build_signers = Some [ Keys.public mike; Keys.public roman ];
      signer_sets = [];
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

(* A node that adopted a signed signer-set change holds the set its chain leaves: a build naming a
   larger set it has not seen (an older supervisor's, a release moved back to) never puts a removed
   signer back. DIG-223 *)
let test_adopted_set_never_widens () =
  let path = Filename.concat (temp_dir ()) "update.json" in
  let s = { (State.initial ()) with trust = trust founders } in
  let s, a =
    State.adopt_sets s ~revocations:[]
      [ signer_set ~by:[ mike; roman; carol ] new_set ]
  in
  Alcotest.(check int) "the change is adopted" 1 (List.length a.adopted);
  Alcotest.(check (list string))
    "Roman removed" [ "Mike"; "Carol" ] (names s.trust);
  State.save path { s with build_signers = Some [ Keys.public mike ] };
  let wider = founders @ [ signer "Carol" carol ] in
  (match State.load ~build:wider path with
  | Ok s ->
      Alcotest.(check (list string))
        "a build not seen before does not widen it" [ "Mike"; "Carol" ]
        (names s.trust)
  | Error e -> Alcotest.fail e);
  (* An older binary that widened the file on its own load: the next load narrows it again. *)
  State.save path { s with trust = { s.trust with signers = wider } };
  match State.load ~build:wider ~reconcile:false path with
  | Ok s ->
      Alcotest.(check (list string))
        "a widened file returns to the chain's set" [ "Mike"; "Carol" ]
        (names s.trust)
  | Error e -> Alcotest.fail e

(* The supervisor writes update.json without reconciling the signer set: its binary's build never
   reaches the file. DIG-223 *)
let test_unreconciled_load_keeps_the_stored_set () =
  let path = Filename.concat (temp_dir ()) "update.json" in
  State.save path
    { (State.initial ()) with trust = trust [ signer "Mike" mike ] };
  match State.load ~build:founders ~reconcile:false path with
  | Ok s ->
      Alcotest.(check int) "the stored one" 1 (List.length s.trust.signers)
  | Error e -> Alcotest.fail e

(* Failures that may be the machine are tried again, and the [strike_limit]th refuses. *)
let test_strikes_refuse_on_the_last () =
  let s = State.initial () in
  let s =
    State.strike s (v "0.2.0") "its self-test failed: timed out" ~now:0.
  in
  (match s.pending with
  | Some p ->
      Alcotest.(check int) "one strike" 1 p.strikes;
      Alcotest.(check bool) "after the backoff" true (p.due_at > 0.)
  | None -> Alcotest.fail "not pending");
  let s =
    List.fold_left
      (fun s _ -> State.strike s (v "0.2.0") "slow" ~now:0.)
      s
      (List.init (State.strike_limit - 1) Fun.id)
  in
  Alcotest.(check bool) "refused" true (State.is_refused s (v "0.2.0"));
  Alcotest.(check bool) "nothing pending" true (s.pending = None)

(* Writers on two threads each read, change and write update.json; the lock loses neither's
   change, and a thread that holds it may take it again. DIG-223 *)
let test_state_updates_are_serialized () =
  let path = Filename.concat (temp_dir ()) "update.json" in
  State.save path (State.initial ());
  let bump () =
    ignore
      (State.update path (fun s ->
           Thread.yield ();
           Ok
             {
               s with
               pin = None;
               refused =
                 s.refused @ [ { refused_version = v "9.9.9"; why = "x" } ];
             }))
  in
  let threads =
    List.init 4 (fun _ ->
        Thread.create
          (fun () ->
            for _ = 1 to 10 do
              bump ()
            done)
          ())
  in
  List.iter Thread.join threads;
  Alcotest.(check int)
    "every change kept" 40
    (List.length (loaded path).refused);
  State.with_lock path (fun () -> bump ());
  Alcotest.(check int) "reentrant" 41 (List.length (loaded path).refused);
  Alcotest.(check bool)
    "no temporary file left" false
    (Sys.file_exists (path ^ ".tmp"))

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

(* The channel's signers/ (docs/releases.md, The channel): sign --next writes every change the node
   holds that the channel lacks, once; a node reading the channel adopts it; and `verify --channel`
   judges a manifest by the set the chain leaves, as ci/release.sh does. *)
let test_signers_channel () =
  let dir = temp_dir () in
  let path name = Filename.concat dir name in
  write_file (path "index.json")
    {|{ "format": "digestif-feed-v0", "releases": [], "revocations": [] }|};
  let change = signer_set ~by:[ mike; roman; carol ] new_set in
  (match Signers_channel.write_sets ~dir [ change ] with
  | Ok [ _ ] -> ()
  | Ok l -> Alcotest.failf "wrote %d changes" (List.length l)
  | Error e -> Alcotest.fail e);
  Alcotest.(check string)
    "the document's exact bytes" change.bytes
    (In_channel.with_open_bin
       (path (Signers_channel.document_path change))
       In_channel.input_all);
  (match Signers_channel.write_sets ~dir [ change ] with
  | Ok [] -> ()
  | _ -> Alcotest.fail "a change the channel lists is written once");
  let feed =
    match Feed.read Feed.default_fetch ~base:dir ~installed:(v "0.1.0") with
    | Ok f -> f
    | Error e -> Alcotest.fail e
  in
  Alcotest.(check int) "the channel lists it" 1 (List.length feed.signer_sets);
  Alcotest.(check (list string))
    "and the set it leaves" [ "Mike"; "Carol" ]
    (List.map
       (fun (s : Release.signer) -> s.name)
       (Signers_channel.current ~build:founders ~channel:(Some feed) ~held:[]));
  let r = release ~by:[ mike; carol ] "0.2.0" in
  write_file (path "manifest.json") r.bytes;
  write_file (path "manifest.sig.json")
    (Release.signatures_to_string r.signatures);
  write_file (path "signers.json")
    (Yojson.Safe.to_string
       (`Assoc
          [
            ("format", `String "digestif-signers-v0");
            ("signers", `List (List.map Release.signer_to_json founders));
          ]));
  let verify extra =
    Sys.command
      (Printf.sprintf
         "../bin/main.exe verify --signers %s %s --expect-version 0.2.0 %s %s \
          >/dev/null 2>&1"
         (Filename.quote (path "signers.json"))
         extra
         (Filename.quote (path "manifest.json"))
         (Filename.quote (path "manifest.sig.json")))
  in
  Alcotest.(check int)
    "the build's set refuses the new set's release" 1 (verify "");
  Alcotest.(check int)
    "the channel's chain accepts it" 0
    (verify ("--channel " ^ Filename.quote dir))

let test_signer_halt () =
  let halted = [ signer "Roman" roman ] in
  Alcotest.(check (option string))
    "an invite is refused while a key is revoked"
    (Some
       "Invites halted: Roman's key is revoked. Remove Roman as admin to lift \
        it.")
    (Signer_halt.refusal ~halted Approval.Invite);
  Alcotest.(check bool)
    "a promotion too" true
    (Signer_halt.refusal ~halted Approval.Promotion <> None);
  Alcotest.(check (option string))
    "a removal starts" None
    (Signer_halt.refusal ~halted Approval.Removal);
  Alcotest.(check (option string))
    "a replacement starts" None
    (Signer_halt.refusal ~halted Approval.Replacement);
  Alcotest.(check bool)
    "a waiting invite ends" true
    (Signer_halt.ends ~halted Approval.Invite);
  Alcotest.(check bool)
    "a waiting removal goes on" false
    (Signer_halt.ends ~halted Approval.Removal);
  Alcotest.(check bool)
    "no halt, nothing ends" false
    (Signer_halt.ends ~halted:[] Approval.Invite)

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

let sim_ops ?(exit_at = None) ?(healthy_at = None) ?(sleep_at = None)
    ?(status = Supervisor.Exited 1) node sim =
  let pid = 4242 in
  {
    Supervisor.spawn =
      (fun exe ->
        sim.spawned <- sim.spawned @ [ exe ];
        pid);
    poll =
      (fun _ ->
        match exit_at with
        | Some n when sim.steps >= n -> Some status
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
  Alcotest.(check string) "current moved back" "0.1.0" (current node);
  let s = loaded (Schedule.state_path node) in
  Alcotest.(check bool)
    "a slow start may be the machine: not refused" false
    (State.is_refused s (v "0.2.0"));
  Alcotest.(check (option int))
    "one strike, tried again after the backoff" (Some 1)
    (Option.map (fun (p : State.pending) -> p.strikes) s.pending)

(* A release that misses its health bound on every try is the release: the last strike refuses it.
   DIG-223 *)
let test_unhealthy_every_try_is_refused () =
  let node = switched_node () in
  for i = 1 to State.strike_limit do
    (if i > 1 then
       match Trial.begin_ node ~release:"0.2.0" ~version:(v "0.2.0") with
       | Ok () -> ()
       | Error e -> Alcotest.fail e);
    ignore (trial_outcome (sim_ops node (new_sim ())) node);
    let s = loaded (Schedule.state_path node) in
    Alcotest.(check bool)
      (Printf.sprintf "refused after try %d" i)
      (i = State.strike_limit)
      (State.is_refused s (v "0.2.0"))
  done;
  let s = loaded (Schedule.state_path node) in
  Alcotest.(check bool) "nothing pending" true (s.pending = None);
  Alcotest.(check bool)
    "the refusal says the machine may be why" true
    (List.exists
       (fun (r : State.refused) -> Status.machine_may_be_why r.why)
       s.refused)

(* A child that exits for its environment (its UI port held) before it reports healthy is rolled
   back without refusing the release. DIG-223 *)
let test_environment_exit_on_trial_is_a_strike () =
  let node = switched_node () in
  let sim = new_sim () in
  let outcome =
    trial_outcome
      (sim_ops ~exit_at:(Some 2)
         ~status:(Supervisor.Exited Supervisor.environment_exit) node sim)
      node
  in
  Alcotest.(check bool)
    "rolled back" true
    (match outcome with Supervisor.Rolled_back _ -> true | _ -> false);
  let s = loaded (Schedule.state_path node) in
  Alcotest.(check bool) "not refused" false (State.is_refused s (v "0.2.0"));
  Alcotest.(check bool) "pending" true (s.pending <> None)

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
  Alcotest.(check bool)
    "nothing to retry" true
    (Status.retryable ~dir:node = None);
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
            cause = "unpacking it took over 60 seconds";
            attempts = 1;
            strikes = 0;
            due_at = 0.;
          };
    };
  (match Status.entries ~dir:node with
  | [ pending; refused ] ->
      Alcotest.(check bool)
        pending.line true
        (contains
           ~sub:
             "Release 0.3.0 could not be installed on this machine yet: \
              unpacking it took over 60 seconds. Still running 0.1.0; the node \
              tries again at"
           pending.line);
      Alcotest.(check bool)
        "a waiting stage can be tried now" true
        (pending.retry = Some (v "0.3.0"));
      Alcotest.(check string)
        "a refusal that is the release's fault says so, with nothing to do"
        "Release 0.2.0 was refused: it exited with status 1 before it reported \
         healthy. That is the release's fault, and the next release replaces \
         it; there is nothing to do. Still running 0.1.0."
        refused.line;
      Alcotest.(check bool) "and offers no retry" true (refused.retry = None)
  | l ->
      Alcotest.fail (String.concat " | " (List.map (fun e -> e.Status.line) l)));
  (* What an older node refused for when the archive was slow to unpack (DIG-255): this machine,
     so a person may try it again. *)
  State.save path
    (State.refuse (loaded path) (v "0.4.0")
       "the release archive did not unpack: tar: still running after 60 seconds");
  match List.rev (Status.entries ~dir:node) with
  | slow :: _ ->
      Alcotest.(check string)
        "a refusal that may be this machine"
        "Release 0.4.0 was refused on this machine: the release archive did \
         not unpack: tar: still running after 60 seconds. Still running 0.1.0."
        slow.line;
      Alcotest.(check bool)
        "offers Try again" true
        (slow.retry = Some (v "0.4.0"))
  | [] -> Alcotest.fail "no entries"

(* A slow unpack or a failed one is this machine, never the release: the archive's bytes are the
   ones both signers signed. It is retried, never refused. DIG-255 *)
let test_unpack_failure_is_retried () =
  let node = temp_dir () in
  (match Stage.from_archive ~dir:node ~version:(v "0.2.0") "not a tar" with
  | Error (Stage.Retry why) ->
      Alcotest.(check bool)
        ("says unpacking failed: " ^ why)
        true
        (contains ~sub:"unpacking it failed" why)
  | Error (Stage.Refuse why) -> Alcotest.failf "refused: %s" why
  | Error (Stage.Suspect why) -> Alcotest.failf "suspected: %s" why
  | Ok _ -> Alcotest.fail "staged garbage");
  Alcotest.(check bool) "nothing staged" false (Layout.staged node "0.2.0");
  (* A tar that never finishes (reading a FIFO nobody writes) runs past its bound. *)
  let dir = temp_dir () in
  let fifo = Filename.concat dir "archive.tar.gz" in
  Unix.mkfifo fifo 0o600;
  let staging = Filename.concat dir "staging" in
  Unix.mkdir staging 0o755;
  match Stage.unpack ~bound:2. ~archive:fifo ~staging () with
  | Error (Stage.Retry why) ->
      Alcotest.(check string)
        "says it took too long" "unpacking it took over 2 seconds" why
  | Error (Stage.Refuse why) -> Alcotest.failf "refused: %s" why
  | Error (Stage.Suspect why) -> Alcotest.failf "suspected: %s" why
  | Ok () -> Alcotest.fail "a tar reading nothing finished"

(* Try again (DIG-255): the refusal goes, a waiting stage is due now, and the next tick checks. *)
let test_retry_clears_refusal () =
  let node = supervised_node () in
  let path = Schedule.state_path node in
  let rpath = Schedule.report_path node in
  Report.save rpath { Report.empty with last_checked_at = Some 1_000. };
  State.save path (State.refuse (loaded path) (v "0.2.0") "slow");
  Alcotest.(check bool)
    "neither refused nor waiting" true
    (Result.is_error (Schedule.retry ~dir:node ~now:2_000. (v "0.9.0")));
  (match Schedule.retry ~dir:node ~now:2_000. (v "0.2.0") with
  | Ok () -> ()
  | Error e -> Alcotest.fail e);
  Alcotest.(check bool)
    "the refusal is gone" false
    (State.is_refused (loaded path) (v "0.2.0"));
  Alcotest.(check bool)
    "the next tick checks" true
    (Schedule.due ~now:2_001. ~woke:false (Report.load rpath));
  State.save path
    {
      (loaded path) with
      pending =
        Some
          {
            pending_version = v "0.3.0";
            cause = "unpacking it took over 60 seconds";
            attempts = 3;
            strikes = 0;
            due_at = 90_000.;
          };
    };
  (match Schedule.retry ~dir:node ~now:2_000. (v "0.3.0") with
  | Ok () -> ()
  | Error e -> Alcotest.fail e);
  Alcotest.(check bool)
    "a waiting stage is due now" true
    (match (loaded path).pending with
    | Some p -> p.due_at = 2_000. && p.attempts = 3
    | None -> false)

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
  Alcotest.(check bool) "a clock that went back" true (due 50. (Some 100.));
  let failing t = { (r t) with failing_since = Some 100. } in
  Alcotest.(check bool)
    "after a failed pass, an hour on without a wake" true
    (Schedule.due ~now:3_700. ~woke:false (failing (Some 100.)));
  Alcotest.(check bool)
    "after a failed pass, not inside the hour" false
    (Schedule.due ~now:200. ~woke:false (failing (Some 100.)))

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
  let pending () = (Report.load (Schedule.report_path node)).pending in
  (match Schedule.pass cfg ~now:1. with
  | Schedule.Not_switched, [ line ] ->
      Alcotest.(check bool)
        ("a failed pass: " ^ line) true
        (contains ~sub:"The update check failed" line)
  | _ -> Alcotest.fail "an unreachable channel did not fail the pass");
  Alcotest.(check (list string))
    "one failed pass is not news for the digest" [] (pending ());
  Alcotest.(check bool)
    "the next pass waits" true
    (Schedule.tick cfg ~now:2. ~woke:false = None);
  Alcotest.(check bool)
    "and runs an hour on, wake or not" true
    (Schedule.tick cfg ~now:(1. +. Schedule.wake_gap) ~woke:false <> None);
  Alcotest.(check (list string)) "still inside the grace" [] (pending ());
  ignore (Schedule.pass cfg ~now:(1. +. Schedule.failure_grace));
  (match pending () with
  | [ line ] ->
      Alcotest.(check bool)
        ("a day of failed passes is reported: " ^ line)
        true
        (contains ~sub:"The update check failed" line)
  | l -> Alcotest.failf "a day of failed passes left %d lines" (List.length l));
  ignore (Schedule.pass cfg ~now:(2. +. Schedule.failure_grace));
  Alcotest.(check int) "and reported once" 1 (List.length (pending ()))

(* A pass that succeeds ends the run of failures: a later failure starts its own grace. *)
let test_schedule_failure_clears () =
  let dir = temp_dir () in
  let node = Filename.concat dir "node" in
  let feed = Filename.concat dir "feed/" in
  let cfg = schedule_config node feed in
  ignore (Schedule.pass cfg ~now:1.);
  channel feed [] ~tamper:false;
  ignore (Schedule.pass cfg ~now:2.);
  let report = Report.load (Schedule.report_path node) in
  Alcotest.(check bool) "cleared" true (report.failing_since = None);
  Sys.remove (Filename.concat feed "index.json");
  ignore (Schedule.pass cfg ~now:(1. +. Schedule.failure_grace));
  Alcotest.(check (list string))
    "a fresh failure is inside its own grace" []
    (Report.load (Schedule.report_path node)).pending;
  match
    Report.of_string
      (Report.to_string (Report.load (Schedule.report_path node)))
  with
  | Ok r ->
      Alcotest.(check bool)
        "failing_since roundtrips" true
        (r.failing_since = Some (1. +. Schedule.failure_grace))
  | Error e -> Alcotest.fail e

(* The index is signed by nobody (DIG-203): under an https channel it may name no path on the node's
   own disk, and every read stops at a bound, so a lying channel can only withhold. *)
let test_resolve_refuses_local_path_under_https () =
  let base = "https://channel.test/feed/" in
  let ok rel = match Feed.resolve ~base rel with Ok t -> t | Error e -> e in
  Alcotest.(check string)
    "a relative entry is under the channel"
    "https://channel.test/feed/index.json" (ok "index.json");
  Alcotest.(check string)
    "an https entry stands" "https://elsewhere.test/a"
    (ok "https://elsewhere.test/a");
  Alcotest.(check bool)
    "an absolute path is refused" true
    (match Feed.resolve ~base "/dev/zero" with
    | Error e -> contains ~sub:"names no local path" e
    | Ok _ -> false);
  Alcotest.(check bool)
    "a channel on disk keeps its absolute paths" true
    (Feed.resolve ~base:"/srv/feed/" "/srv/other/manifest.json"
    = Ok "/srv/other/manifest.json")

let test_https_index_naming_a_local_path () =
  let asked = ref [] in
  let index =
    Yojson.Safe.to_string
      (`Assoc
         [
           ("format", `String "digestif-feed-v0");
           ( "releases",
             `List
               [
                 `Assoc
                   [
                     ("version", `String "9.0.0");
                     ("manifest", `String "/dev/zero");
                     ("signatures", `String "/dev/zero");
                   ];
               ] );
         ])
  in
  let fetch ~limit target =
    asked := (target, limit) :: !asked;
    if target = "https://channel.test/feed/index.json" then Ok index
    else Error (target ^ ": not served")
  in
  match
    Feed.read fetch ~base:"https://channel.test/feed/" ~installed:(v "0.1.0")
  with
  | Error e -> Alcotest.fail e
  | Ok f ->
      Alcotest.(check int) "no release" 0 (List.length f.releases);
      Alcotest.(check bool)
        "the entry is a problem" true
        (List.exists (contains ~sub:"names no local path") f.problems);
      Alcotest.(check (list (pair string int)))
        "only the index was read, at the document bound"
        [ ("https://channel.test/feed/index.json", Feed.document_limit) ]
        !asked

let test_fetch_is_bounded () =
  let dir = temp_dir () in
  let path = Filename.concat dir "doc" in
  write path (String.make 10 'a');
  Alcotest.(check bool)
    "a document at the bound reads" true
    (Feed.default_fetch ~limit:10 path = Ok (String.make 10 'a'));
  Alcotest.(check bool)
    "one byte past it is refused" true
    (match Feed.default_fetch ~limit:9 path with
    | Error e -> contains ~sub:"longer than the 9 bytes" e
    | Ok _ -> false);
  Alcotest.(check bool)
    "an endless device stops at the bound" true
    (match Feed.default_fetch ~limit:100_000 "/dev/zero" with
    | Error e -> contains ~sub:"longer than" e
    | Ok _ -> false);
  (* A channel on disk whose index names an endless manifest reports it and reads the rest. *)
  let feed = Filename.concat dir "feed/" in
  write
    (Filename.concat feed "index.json")
    {|{ "format": "digestif-feed-v0", "releases": [ { "version": "9.0.0", "manifest": "/dev/zero", "signatures": "/dev/zero" } ] }|};
  match Feed.read Feed.default_fetch ~base:feed ~installed:(v "0.1.0") with
  | Error e -> Alcotest.fail e
  | Ok f ->
      Alcotest.(check bool)
        "the endless entry is a problem" true
        (List.exists (contains ~sub:"longer than") f.problems)

(* The archive is read no further than the size its signed manifest states. *)
let test_archive_bounded_by_signed_size () =
  let dir = temp_dir () in
  let feed = Filename.concat dir "feed/" in
  channel feed [ release ~by:[ mike; roman ] "0.2.0" ] ~tamper:false;
  let node = supervised_node () in
  let limits = ref [] in
  let fetch ~limit target =
    if contains ~sub:"artifacts/" target then
      limits := (limit, (Unix.stat target).st_size) :: !limits;
    Feed.default_fetch ~limit target
  in
  let o = update ~fetch ~feed node in
  Alcotest.(check bool)
    "it switches" true
    (o.step = Updater.Switched (v "0.2.0"));
  match !limits with
  | [ (limit, size) ] ->
      Alcotest.(check int) "bounded by the manifest's size" size limit
  | l -> Alcotest.failf "the archive was read %d times" (List.length l)

let test_curl_cause () =
  Alcotest.(check (option string))
    "exit 6 names the cause"
    (Some "the host name did not resolve: no network or no DNS")
    (Feed.curl_cause 6);
  Alcotest.(check (option string)) "an unknown code" None (Feed.curl_cause 99)

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
let crash_once ?(ran = 60) ?(spawn = fun () -> ())
    ?(status = Supervisor.Exited 1) node =
  let crashes = ref [] in
  let ops =
    let ops = sim_ops ~exit_at:(Some ran) ~status node (new_sim ()) in
    {
      ops with
      spawn =
        (fun exe ->
          spawn ();
          ops.spawn exe);
    }
  in
  let exited = status in
  let status =
    Supervisor.run ~on_crash:(fun c -> crashes := c :: !crashes) ops node
  in
  Alcotest.(check bool) "the child's exit" true (status = exited);
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
  Alcotest.(check int)
    "the count starts over" 0
    (exits_counted node ~release:"0.1.6");
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

(* Only an exit the release is answerable for counts: one for the environment (the UI port held)
   and a stop somebody asked for add their awake time and nothing else. A crash by signal counts.
   DIG-205 *)
let test_only_abnormal_exits_count () =
  let node = node_with [ ("0.1.6", 0.); ("0.1.7", day) ] ~running:"0.1.7" in
  let not_counted =
    [
      Supervisor.Exited Supervisor.environment_exit;
      Exited 0;
      Signaled Sys.sigterm;
      Signaled Sys.sigint;
      Exited Supervisor.environment_exit;
      Exited Supervisor.environment_exit;
    ]
  in
  List.iter
    (fun status ->
      Alcotest.(check int) "no move" 0 (List.length (crash_once ~status node)))
    not_counted;
  Alcotest.(check string) "still on 0.1.7" "0.1.7" (current node);
  Alcotest.(check int) "nothing counted" 0 (exits_counted node ~release:"0.1.7");
  Alcotest.(check (float 6.))
    "their awake time is" 360. (Crashes.load node ~release:"0.1.7").awake;
  ignore (crash_once ~status:(Signaled Sys.sigsegv) node);
  ignore (crash_once ~status:(Exited 125) node);
  Alcotest.(check int)
    "a crash by signal and an uncaught exception count" 2
    (exits_counted node ~release:"0.1.7")

(* Two releases crashing in turn is this machine, not a release: the node moves back once, and the
   release it moved back to stays, unrefused, however often it crashes after. DIG-205 *)
let test_crash_moves_back_once () =
  let node =
    node_with
      [ ("0.1.5", 0.); ("0.1.6", day); ("0.1.7", 2. *. day) ]
      ~running:"0.1.7"
  in
  ignore (crash_once node);
  ignore (crash_once node);
  (match crash_once node with
  | [ Supervisor.Crashed_back (_, to_) ] ->
      Alcotest.(check string) "moved back" "0.1.6" (Version.to_string to_)
  | _ -> Alcotest.fail "expected one move back");
  ignore (Report.take (Schedule.report_path node));
  Alcotest.(check (option string))
    "0.1.6's count says where it came from" (Some "0.1.7")
    (Crashes.load node ~release:"0.1.6").moved_back_from;
  for round = 1 to 2 do
    ignore (crash_once node);
    ignore (crash_once node);
    (match crash_once node with
    | [ Supervisor.Crashed_stayed (v, _) ] ->
        Alcotest.(check string)
          (Printf.sprintf "round %d stays" round)
          "0.1.6" (Version.to_string v)
    | _ -> Alcotest.fail "expected the node to stay");
    Alcotest.(check string) "current stays" "0.1.6" (current node);
    Alcotest.(check (option string))
      "good stays" (Some "0.1.6") (Layout.good node)
  done;
  let s = loaded (Schedule.state_path node) in
  Alcotest.(check bool)
    "0.1.6 is not refused" false
    (State.is_refused s (v "0.1.6"));
  Alcotest.(check bool)
    "0.1.5 is not refused" false
    (State.is_refused s (v "0.1.5"));
  Alcotest.(check (list string))
    "the digest says why"
    [
      "Digestif 0.1.6 kept crashing, and it is the release this node went back \
       to from 0.1.7 for crashing, which makes this machine the likely cause, \
       so it keeps restarting until the next release.";
    ]
    (List.sort_uniq compare (Report.take (Schedule.report_path node)))

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

(* The releases listing a fake gh answers, which sign --next's caller reads once and hands to
   Sign_next.run. *)
let listing gh =
  match gh [ "api"; Sign_next.releases_path "o/r" ] with
  | Ok s -> s
  | Error e -> Alcotest.fail e

(* sign --next's git against a fake clone: [shas] the commit each tag names in it, [logs] what
   `git log` answers for a range, [paths] ci/relay-release-paths at a tag. Every call is recorded
   in [calls]. *)
let fake_git ?(calls = ref []) ?(paths = []) ?(files = []) ~shas ~logs () =
  let suffix = "^{commit}" in
  fun args ->
    calls := !calls @ [ args ];
    match args with
    | [ "-C"; _; "fetch"; "--quiet"; "--tags"; "--force"; "origin" ] -> Ok ""
    | [ "-C"; _; "config"; "--get"; "remote.origin.partialclonefilter" ] ->
        Error "git config exited 1: "
    | [ "-C"; _; "rev-parse"; "--verify"; r ] when String.ends_with ~suffix r
      -> (
        let tag = String.sub r 0 (String.length r - String.length suffix) in
        match List.assoc_opt tag shas with
        | Some sha -> Ok (sha ^ "\n")
        | None -> Error ("fatal: Needed a single revision: " ^ r))
    | "-C" :: _ :: "log" :: "--format=%s" :: range :: _ ->
        Ok (Option.value (List.assoc_opt range logs) ~default:"")
    | [ "-C"; _; "ls-tree"; "--name-only"; tag; "ci/relay-release-paths" ] ->
        Ok (if List.mem_assoc tag paths then "ci/relay-release-paths\n" else "")
    | [ "-C"; _; "show"; spec ] when List.mem_assoc spec files ->
        Ok (List.assoc spec files)
    | [ "-C"; _; "show"; spec ] -> (
        match String.index_opt spec ':' with
        | Some i -> (
            match List.assoc_opt (String.sub spec 0 i) paths with
            | Some text -> Ok text
            | None -> Error ("fatal: path does not exist: " ^ spec))
        | None -> Error ("unexpected git show " ^ spec))
    | _ -> Error ("unexpected git " ^ String.concat " " args)

(* GitHub's artifact attestations as a fake gh answers `gh attestation verify` (Attestation): a file
   is attested when [attested] holds its sha256, by the workflow, on the ref and at the commit the
   question names, unless [at] names another commit the certificate carries. *)
let attest_run = "https://github.com/o/r/actions/runs/77/attempts/1"

let fake_attest ?(attested = fun _ -> true) ?at args =
  match args with
  | "attestation" :: "verify" :: path :: flags ->
      let rec flag k = function
        | a :: b :: _ when a = k -> b
        | _ :: r -> flag k r
        | [] -> ""
      in
      let sha =
        Keys.hash_of_bytes (In_channel.with_open_bin path In_channel.input_all)
      in
      if not (attested sha) then
        Some (Error "gh attestation exited 1: Error: no attestations found")
      else
        let cert =
          `Assoc
            [
              ( "buildSignerURI",
                `String
                  ("https://github.com/"
                  ^ flag "--signer-workflow" flags
                  ^ "@" ^ flag "--source-ref" flags) );
              ("sourceRepositoryRef", `String (flag "--source-ref" flags));
              ( "sourceRepositoryDigest",
                `String
                  (Option.value at ~default:(flag "--source-digest" flags)) );
              ("runnerEnvironment", `String "github-hosted");
              ("runInvocationURI", `String attest_run);
            ]
        in
        let subject =
          `Assoc
            [
              ("name", `String (Filename.basename path));
              ("digest", `Assoc [ ("sha256", `String (Attestation.hex sha)) ]);
            ]
        in
        Some
          (Ok
             (Yojson.Safe.to_string
                (`List
                   [
                     `Assoc
                       [
                         ( "verificationResult",
                           `Assoc
                             [
                               ("signature", `Assoc [ ("certificate", cert) ]);
                               ( "statement",
                                 `Assoc [ ("subject", `List [ subject ]) ] );
                             ] );
                       ];
                   ])))
  | _ -> None

let with_attest ?attested ?at gh args =
  match fake_attest ?attested ?at args with Some r -> r | None -> gh args

(* How a node draft holds its archive: as the manifest names it, not at all, without a digest, or
   with a digest that differs. *)
type archive =
  | Archive_ok
  | Archive_missing
  | Archive_no_digest
  | Archive_differs

let archive_asset ?(archive = Archive_ok) id version =
  let base = [ ("id", `Int id); ("name", `String version) ] in
  match archive with
  | Archive_missing -> []
  | Archive_no_digest -> [ `Assoc base ]
  | Archive_differs -> [ `Assoc (base @ [ ("digest", `String (sha 1)) ]) ]
  | Archive_ok ->
      [
        `Assoc
          (base
          @ [ ("digest", `String (Keys.hash_of_bytes (binary_bytes version))) ]
          );
      ]

let gh_releases ?(signed_by = []) ?archive () =
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
                 ((asset 21 "manifest.json" :: archive_asset ?archive 25 "0.2.1")
                 @ List.mapi
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

let fake_gh ?signed_by ?(manifest = manifest_json "0.2.1") ?archive ?attested
    ?at () =
  let f = { calls = ref []; uploaded = ref None; keys_read = ref 0 } in
  let answer args =
    match args with
    | [ "api"; "repos/o/r/releases?per_page=50" ] ->
        Ok (gh_releases ?signed_by ?archive ())
    | [ "api"; "-H"; _; "repos/o/r/releases/assets/21" ] -> Ok manifest
    | [ "api"; "-H"; _; "repos/o/r/releases/assets/25" ] ->
        Ok (binary_bytes "0.2.1")
    | [ "release"; "upload"; "v0.2.1"; path; "--repo"; "o/r"; "--clobber" ] ->
        f.uploaded := Some path;
        Ok ""
    | [ "release"; "delete"; "v0.2.1"; "--repo"; "o/r"; "--yes" ] -> Ok ""
    | _ -> Error ("unexpected gh " ^ String.concat " " args)
  in
  let gh args =
    f.calls := !(f.calls) @ [ args ];
    with_attest ?attested ?at answer args
  in
  (f, gh)

let run_next ?signed_by ?manifest ?archive ?attested ?at ?(key = mike) ?ask
    answer =
  let f, gh = fake_gh ?signed_by ?manifest ?archive ?attested ?at () in
  let said = Buffer.create 256 in
  let read_key () =
    incr f.keys_read;
    Ok (Keys.encode_secret key ^ "\n")
  in
  let git =
    fake_git
      ~shas:[ ("v0.2.1", "abc123"); ("v0.2.0", "aaa000") ]
      ~logs:[ ("v0.2.0..v0.2.1", "Fix the digest\nAdd a recall\n") ]
      ()
  in
  let result =
    Sign_next.run ~gh ~git ~clone:(temp_dir ()) ~signers:founders
      ~config:
        { Sign_next.key_command = "unused"; repo = "o/r"; public_key = None }
      ~read_key
      ~ask:
        (match ask with
        | Some ask -> ask ~say:(fun l -> Buffer.add_string said (l ^ "\n"))
        | None -> fun _ -> answer)
      ~say:(fun l -> Buffer.add_string said (l ^ "\n"))
      ~tmp:(temp_dir ()) ~relay:Sign_next.no_relay ~timer:Timing.none
      ~listed:(listing gh)
  in
  (f, result, Buffer.contents said)

(* --sign answers the question itself: the run signs and uploads, and the question is printed with
   its answer. *)
let test_sign_next_sign_flag () =
  let f, result, said = run_next ~ask:Sign_next.answer_sign "" in
  (match result with Ok () -> () | Error e -> Alcotest.fail e);
  Alcotest.(check bool)
    ("prints the question answered: " ^ said)
    true
    (contains ~sub:"anything else leaves it waiting: s" said);
  Alcotest.(check bool) "uploads the signature" true (!(f.uploaded) <> None)

let test_sign_next_signs () =
  let f, result, said = run_next "s\n" in
  (match result with Ok () -> () | Error e -> Alcotest.fail e);
  List.iter
    (fun sub ->
      Alcotest.(check bool) ("shows " ^ sub) true (contains ~sub said))
    [
      "Digestif 0.2.1";
      "abc123";
      "built   " ^ attest_run;
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
  Alcotest.(check int) "a drop never reads the key" 0 !(f.keys_read);
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
  Alcotest.(check int) "a leave never reads the key" 0 !(f.keys_read);
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
               ( "assets",
                 `List (asset 21 "manifest.json" :: archive_asset 25 "0.2.1") );
             ];
         ]
       else []))

type relay_fake = {
  r_calls : string list list ref;
  r_uploaded : string option ref;
  r_git : string list list ref;
}

let relay_answer f ?node_draft ?draft ?(relay_bytes = bytes_030) ~signed_by args
    =
  match args with
  | [ "api"; "repos/o/r/releases?per_page=50" ] ->
      Ok (relay_listing ?node_draft ?draft ~signed_by ())
  | [ "api"; "-H"; _; "repos/o/r/releases/assets/51" ] -> Ok relay_bytes
  | [ "api"; "-H"; _; "repos/o/r/releases/assets/52" ] -> Ok "1"
  | [ "api"; "-H"; _; "repos/o/r/releases/assets/41" ] -> Ok bytes_020
  | [ "api"; "-H"; _; "repos/o/r/releases/assets/21" ] ->
      Ok (manifest_json "0.2.1")
  | [ "api"; "-H"; _; "repos/o/r/releases/assets/25" ] ->
      Ok (binary_bytes "0.2.1")
  | [ "api"; "-H"; _; "repos/o/r/releases/assets/53" ] ->
      Ok (relay_sig_asset mike)
  | [ "api"; "-H"; _; "repos/o/r/releases/assets/54" ] ->
      Ok (relay_sig_asset roman)
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

let relay_gh ?node_draft ?draft ?relay_bytes ~signed_by () =
  let f = { r_calls = ref []; r_uploaded = ref None; r_git = ref [] } in
  let gh args =
    f.r_calls := !(f.r_calls) @ [ args ];
    with_attest (relay_answer f ?node_draft ?draft ?relay_bytes ~signed_by) args
  in
  (f, gh)

let run_relay ?node_draft ?relay_bytes ?(signed_by = []) ?(key = mike)
    ?(answers = [ "s" ]) ?(migration = migration_text) () =
  let f, gh = relay_gh ?node_draft ?relay_bytes ~signed_by () in
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
  let git =
    fake_git ~calls:f.r_git
      ~shas:
        [
          ("relay-v0.3.0", "def456");
          ("relay-v0.2.0", "rel020");
          ("v0.2.1", "abc123");
          ("v0.2.0", "aaa000");
        ]
      ~logs:
        [
          ("relay-v0.2.0..relay-v0.3.0", "Report the relay version\n");
          ("v0.2.0..v0.2.1", "Fix the digest\n");
        ]
      ~paths:
        [
          ( "relay-v0.3.0",
            "# the relay\n\
             relay/src\n\n\
             relay/migrations\n\
             :(exclude,glob)relay/**/*.test.ts\n" );
        ]
      ~files:
        [ ("relay-v0.3.0:relay/migrations/0003_relay_version.sql", migration) ]
      ()
  in
  let result =
    Sign_next.run ~gh ~git ~clone:(temp_dir ()) ~signers:founders
      ~config:
        { Sign_next.key_command = "unused"; repo = "o/r"; public_key = None }
      ~read_key:(fun () -> Ok (Keys.encode_secret key ^ "\n"))
      ~ask:(fun _ ->
        match !answers with
        | a :: rest ->
            answers := rest;
            a
        | [] -> "")
      ~say:(fun l -> Buffer.add_string said (l ^ "\n"))
      ~tmp:(temp_dir ()) ~relay ~timer:Timing.none ~listed:(listing gh)
  in
  (f, result, Buffer.contents said, !published)

(* A document with a member twice reads one way to OCaml (the first) and another to JSON.parse (the
   last), so [extra] is spliced in as the object's last member, after the one it repeats. *)
let with_last_member extra bytes =
  let close = String.rindex bytes '}' in
  String.sub bytes 0 close ^ ",\n  " ^ extra ^ "\n}\n"

let expect_refused ~sub result =
  match result with
  | Ok () -> Alcotest.fail "a document not in its canonical form was signed"
  | Error e ->
      Alcotest.(check bool)
        ("refuses with " ^ sub ^ ": " ^ e)
        true (contains ~sub e)

let test_sign_next_refuses_duplicate_member () =
  let other =
    Printf.sprintf
      {|"artifacts": [ { "platform": %S, "url": "artifacts/evil", "sha256": "sha256:%s", "size": 1 } ]|}
      platform (String.make 64 'a')
  in
  let f, result, _ =
    run_next ~manifest:(with_last_member other (manifest_json "0.2.1")) "s"
  in
  expect_refused ~sub:"\"artifacts\" twice" result;
  Alcotest.(check int) "the key is never read" 0 !(f.keys_read);
  Alcotest.(check bool) "nothing uploaded" true (!(f.uploaded) = None)

let test_sign_next_refuses_non_canonical () =
  (* The same manifest, one space short of what the manifest command writes. *)
  let bytes = manifest_json "0.2.1" in
  let bytes = String.sub bytes 0 (String.length bytes - 1) in
  let f, result, _ = run_next ~manifest:bytes "s" in
  expect_refused ~sub:"not in its canonical form" result;
  Alcotest.(check bool) "nothing uploaded" true (!(f.uploaded) = None)

let test_sign_relay_refuses_duplicate_bundle () =
  let other =
    Printf.sprintf
      {|"bundle": { "url": "https://evil.example/bundle.tar.gz", "sha256": "sha256:%s", "size": 1 }|}
      (String.make 64 'b')
  in
  let f, result, _, published =
    run_relay ~relay_bytes:(with_last_member other bytes_030) ()
  in
  expect_refused ~sub:"\"bundle\" twice" result;
  Alcotest.(check bool) "nothing uploaded" true (!(f.r_uploaded) = None);
  Alcotest.(check int) "nothing published" 0 (List.length published)

let test_sign_relay_shows () =
  let f, result, said, _ = run_relay ~answers:[ "" ] () in
  (match result with Ok () -> () | Error e -> Alcotest.fail e);
  List.iter
    (fun sub ->
      Alcotest.(check bool)
        ("shows " ^ sub ^ "\n" ^ said)
        true (contains ~sub said))
    [
      "No node version is waiting for signatures.";
      "Digestif relay 0.3.0, waiting for signatures on o/r";
      "def456";
      "built   " ^ attest_run;
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
    "git log reads the range through the tag's relay paths, comments left out"
    true
    (List.exists
       (fun args ->
         List.mem "relay-v0.2.0..relay-v0.3.0" args
         &&
         match List.rev args with
         | spec :: m :: s :: "--" :: _ ->
             (s, m, spec)
             = ( "relay/src",
                 "relay/migrations",
                 ":(exclude,glob)relay/**/*.test.ts" )
         | _ -> false)
       !(f.r_git));
  Alcotest.(check bool)
    "a tag's commit is read from the clone" true
    (List.mem "relay-v0.3.0^{commit}" (List.concat !(f.r_git)));
  Alcotest.(check (list (list string)))
    "GitHub is asked only for the draft's files and their attestations" []
    (List.filter
       (fun c ->
         match c with
         | [ "api"; "-H"; "Accept: application/octet-stream"; a ] ->
             not (contains ~sub:"releases/assets/" a)
         | [ "api"; "repos/o/r/releases?per_page=50" ] -> false
         | "attestation" :: "verify" :: _ -> false
         | _ -> true)
       !(f.r_calls));
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
    Sign_next.run ~gh
      ~git:(fun _ -> Alcotest.fail "ran git with nothing to show")
      ~clone:(temp_dir ()) ~signers:founders
      ~config:
        { Sign_next.key_command = "unused"; repo = "o/r"; public_key = None }
      ~read_key:(fun () -> Alcotest.fail "read a key with nothing to sign")
      ~ask:(fun _ -> Alcotest.fail "asked with nothing to sign")
      ~say:ignore ~tmp:(temp_dir ()) ~relay:Sign_next.no_relay
      ~timer:Timing.none ~listed:listing
  with
  | Ok () -> Alcotest.fail "an unread draft passed in silence"
  | Error e ->
      Alcotest.(check bool)
        ("names the draft: " ^ e) true
        (contains ~sub:"frob-v1.0.0" e
        && contains ~sub:"newest node release that is not a draft" e)

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

(* Two node versions waiting at once, v0.2.2 and v0.2.1, against a fake gh (digestif#265);
   [older_signed_by] signed v0.2.1. *)
let run_two ?(older_signed_by = []) ?newest_archive answers =
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
           release "v0.2.2" true
             (asset 22 "manifest.json"
             :: archive_asset ?archive:newest_archive 26 "0.2.2");
           release "v0.2.1" true
             ((asset 21 "manifest.json" :: archive_asset 25 "0.2.1")
             @ List.mapi
                 (fun i k ->
                   asset (60 + i)
                     (Sign_next.signature_asset_name (Keys.public k)))
                 older_signed_by);
           release "v0.2.0" false [ asset 11 "manifest.json" ];
           release "v0.1.9" true [ asset 19 "manifest.json" ];
         ])
  in
  let uploaded = ref [] and asked = ref 0 and keys = ref 0 in
  let gh =
    with_attest @@ fun args ->
    match args with
    | [ "api"; "repos/o/r/releases?per_page=50" ] -> Ok listed
    | [ "api"; "-H"; _; "repos/o/r/releases/assets/21" ] ->
        Ok (manifest_json "0.2.1")
    | [ "api"; "-H"; _; "repos/o/r/releases/assets/22" ] ->
        Ok (manifest_json "0.2.2")
    | [ "api"; "-H"; _; "repos/o/r/releases/assets/25" ] ->
        Ok (binary_bytes "0.2.1")
    | [ "api"; "-H"; _; "repos/o/r/releases/assets/26" ] ->
        Ok (binary_bytes "0.2.2")
    | [ "release"; "upload"; tag; _; "--repo"; "o/r"; "--clobber" ] ->
        uploaded := !uploaded @ [ tag ];
        Ok ""
    | [ "release"; "delete"; "v0.1.9"; "--repo"; "o/r"; "--yes" ] -> Ok ""
    | _ -> Error ("unexpected gh " ^ String.concat " " args)
  in
  let git =
    fake_git
      ~shas:[ ("v0.2.2", "abc123"); ("v0.2.1", "abc123"); ("v0.2.0", "abc123") ]
      ~logs:[] ()
  in
  let said = Buffer.create 256 in
  let answers = ref answers in
  let result =
    Sign_next.run ~gh ~git ~clone:(temp_dir ()) ~signers:founders
      ~config:
        { Sign_next.key_command = "unused"; repo = "o/r"; public_key = None }
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
      ~tmp:(temp_dir ()) ~relay:Sign_next.no_relay ~timer:Timing.none
      ~listed:(listing gh)
  in
  (match result with Ok () -> () | Error e -> Alcotest.fail e);
  (!uploaded, !asked, !keys, Buffer.contents said)

(* The node line offers its newest draft, and an older one only when one more signature completes
   it (ISS-52997). *)
let test_sign_next_offers_newest_and_completable () =
  let uploaded, asked, keys, said = run_two [ "s" ] in
  Alcotest.(check (list string))
    "an older draft nobody signed is skipped" [ "v0.2.2" ] uploaded;
  Alcotest.(check bool)
    ("the skipped draft is not shown: " ^ said)
    false
    (contains ~sub:"v0.2.1" said);
  Alcotest.(check int) "asked once" 1 asked;
  Alcotest.(check int) "the key is read once" 1 keys;
  let uploaded, _, _, said = run_two ~older_signed_by:[ roman ] [ "s" ] in
  Alcotest.(check (list string))
    "one s signs the newest and the one Roman signed, newest first"
    [ "v0.2.2"; "v0.2.1" ] uploaded;
  Alcotest.(check bool)
    ("the newest in full: " ^ said)
    true
    (contains ~sub:"Digestif 0.2.2" said);
  Alcotest.(check bool)
    ("an older one in a line: " ^ said)
    true
    (contains ~sub:"also v0.2.1: signed by Roman" said);
  Alcotest.(check bool)
    ("one question for both: " ^ said)
    true
    (contains ~sub:"s signs all 2 versions" (Sign_next.question ~count:2));
  Alcotest.(check bool)
    ("a draft older than the published version is not offered: " ^ said)
    false
    (contains ~sub:"also v0.1.9" said || contains ~sub:"Digestif 0.1.9" said);
  Alcotest.(check bool)
    ("it is dropped once the question is answered: " ^ said)
    true
    (contains
       ~sub:
         "Dropped v0.1.9, a draft older than v0.2.0, the newest published \
          version of its line"
       said);
  let uploaded, asked, keys, _ = run_two ~older_signed_by:[ roman ] [ "" ] in
  Alcotest.(check (list string)) "anything else signs nothing" [] uploaded;
  Alcotest.(check int) "still one question" 1 asked;
  Alcotest.(check int) "and never reads the key" 0 keys

(* A VERSION NOTHING TIES TO ITS BUILD IS NEVER SIGNED (DIG-244): a draft whose archive differs from
   its manifest, is missing, has no digest, or is not attested by release.yml on the tag at the
   commit shown is shown with why, and offered for nothing: no question (so neither s nor --sign
   signs it), no key read, no upload, no drop, and the run fails. *)
let test_sign_next_refuses_unattested () =
  let archive_sha = Keys.hash_of_bytes (binary_bytes "0.2.1") in
  List.iter
    (fun (what, archive, attested, at, reason) ->
      let f, result, said =
        run_next ?archive ?attested ?at
          ~ask:(fun ~say:_ _ -> Alcotest.fail (what ^ ": asked"))
          "s"
      in
      (match result with
      | Ok () -> Alcotest.fail (what ^ ": nothing signable is not an error")
      | Error e ->
          Alcotest.(check bool)
            (what ^ ", the run fails: " ^ e)
            true
            (contains ~sub:"v0.2.1 cannot be signed" e));
      List.iter
        (fun sub ->
          Alcotest.(check bool)
            (what ^ ", shows " ^ sub ^ ": " ^ said)
            true (contains ~sub said))
        [ "NOT OFFERED"; reason ];
      Alcotest.(check int) (what ^ ": no key read") 0 !(f.keys_read);
      Alcotest.(check bool)
        (what ^ ": nothing uploaded")
        true (!(f.uploaded) = None);
      Alcotest.(check bool)
        (what ^ ": nothing uploaded or deleted")
        false
        (List.exists
           (fun c -> List.mem "upload" c || List.mem "delete" c)
           !(f.calls)))
    [
      ( "an archive that differs",
        Some Archive_differs,
        None,
        None,
        "the draft's 0.2.1 is " ^ sha 1 );
      ( "an archive not on the draft",
        Some Archive_missing,
        None,
        None,
        "0.2.1 is not on the draft" );
      ( "an archive without a digest",
        Some Archive_no_digest,
        None,
        None,
        "GitHub holds no digest for the draft's 0.2.1" );
      ( "an unattested archive",
        None,
        Some (fun d -> d <> archive_sha),
        None,
        "0.2.1: no attestation by release.yml on v0.2.1 at abc123" );
      ( "an unattested manifest",
        None,
        Some (fun d -> d = archive_sha),
        None,
        "manifest.json: no attestation by release.yml" );
      ( "an attestation of another commit",
        None,
        None,
        Some "fff999",
        "on a GitHub-hosted runner" );
    ]

(* An unsignable newest version does not keep an older one from being signed: s signs only what
   its build attested. *)
let test_sign_next_signs_only_attested () =
  let uploaded, asked, _, said =
    run_two ~older_signed_by:[ roman ] ~newest_archive:Archive_differs [ "s" ]
  in
  Alcotest.(check (list string)) "only v0.2.1 is signed" [ "v0.2.1" ] uploaded;
  Alcotest.(check int) "asked once" 1 asked;
  Alcotest.(check bool)
    ("names what was not offered: " ^ said)
    true
    (contains
       ~sub:"Not offered, since nothing ties its files to its build: v0.2.2."
       said)

(* A relay migration that is not the tag's file makes the relay version unsignable. *)
let test_sign_relay_refuses_migration () =
  let f, result, said, published =
    run_relay ~migration:"DROP TABLE circle;\n" ()
  in
  Alcotest.(check bool) "the run fails" true (Result.is_error result);
  Alcotest.(check bool)
    ("says why: " ^ said) true
    (contains
       ~sub:"migration 0003_relay_version.sql differs from the tag's file" said);
  Alcotest.(check bool) "nothing uploaded" true (!(f.r_uploaded) = None);
  Alcotest.(check int) "nothing published" 0 (List.length published)

(* gh's answer is read back: an attestation by another workflow, on another ref, at another
   commit, of another file, or on a self-hosted runner names no run. *)
let test_attestation_runs_of_json () =
  let sha256 = Keys.hash_of_bytes "x" in
  let answer
      ?(signer =
        "https://github.com/O/R/.github/workflows/release.yml@refs/tags/v1.0.0")
      ?(ref_ = "refs/tags/v1.0.0") ?(digest = "abc") ?(runner = "github-hosted")
      ?(subject = Attestation.hex sha256) () =
    Yojson.Safe.to_string
      (`List
         [
           `Assoc
             [
               ( "verificationResult",
                 `Assoc
                   [
                     ( "signature",
                       `Assoc
                         [
                           ( "certificate",
                             `Assoc
                               [
                                 ("buildSignerURI", `String signer);
                                 ("sourceRepositoryRef", `String ref_);
                                 ("sourceRepositoryDigest", `String digest);
                                 ("runnerEnvironment", `String runner);
                                 ("runInvocationURI", `String "run");
                               ] );
                         ] );
                     ( "statement",
                       `Assoc
                         [
                           ( "subject",
                             `List
                               [
                                 `Assoc
                                   [
                                     ("name", `String "f");
                                     ( "digest",
                                       `Assoc [ ("sha256", `String subject) ] );
                                   ];
                               ] );
                         ] );
                   ] );
             ];
         ])
  in
  let runs bytes =
    Attestation.runs_of_json ~repo:"o/r" ~workflow:"release.yml" ~tag:"v1.0.0"
      ~commit:"abc" ~sha256 bytes
  in
  Alcotest.(check (result (list string) string))
    "the build's" (Ok [ "run" ])
    (runs (answer ()));
  List.iter
    (fun (what, bytes) ->
      Alcotest.(check (result (list string) string)) what (Ok []) (runs bytes))
    [
      ( "another workflow",
        answer
          ~signer:
            "https://github.com/o/r/.github/workflows/evil.yml@refs/tags/v1.0.0"
          () );
      ("another ref", answer ~ref_:"refs/heads/main" ());
      ("another commit", answer ~digest:"def" ());
      ("a self-hosted runner", answer ~runner:"self-hosted" ());
      ( "another file",
        answer ~subject:(Attestation.hex (Keys.hash_of_bytes "y")) () );
    ]

let test_sign_next_offered () =
  let tags l =
    List.map
      (fun (r : Sign_next.draft) -> r.tag)
      (Sign_next.offered
         ~remaining:(fun (r : Sign_next.draft) ->
           if r.assets = [] then 2 else 1)
         l)
  in
  Alcotest.(check (list string))
    "the newest, and the older ones one signature completes"
    [ "v0.3.4"; "v0.3.1" ]
    (tags
       [
         draft "v0.3.4" true false;
         draft "v0.3.3" true false;
         draft "v0.3.2" true false;
         draft "v0.3.1" true true;
       ]);
  Alcotest.(check (list string))
    "a signed newest is still the newest" [ "v0.3.2" ]
    (tags [ draft "v0.3.2" true true; draft "v0.3.1" true false ]);
  let mine l =
    List.map
      (fun (r : Sign_next.draft) -> r.tag)
      (Sign_next.offered
         ~mine:(fun (r : Sign_next.draft) -> r.tag <> "v0.3.1")
         ~remaining:(fun (r : Sign_next.draft) ->
           if r.assets = [] then 2 else 1)
         l)
  in
  Alcotest.(check (list string))
    "the running signer's drafts are left out, the newest included" [ "v0.3.1" ]
    (mine
       [
         draft "v0.3.4" true false;
         draft "v0.3.3" true true;
         draft "v0.3.1" true true;
       ]);
  Alcotest.(check (list string)) "nothing waiting" [] (tags [])

(* Six relay drafts at once, relay-v0.1.7 through relay-v0.1.12, after relay-v0.1.6 (ISS-52997):
   [signed_by] says who signed which, by patch number. *)
let run_relays_result ?public_key ~published ~patches ~signed_by ~key answer =
  let tag n = Printf.sprintf "relay-v0.1.%d" n in
  let asset ?digest id name =
    `Assoc
      ([ ("id", `Int id); ("name", `String name) ]
      @ match digest with Some d -> [ ("digest", `String d) ] | None -> [])
  in
  let doc n =
    Release.relay_manifest_to_string
      (relay_manifest (Printf.sprintf "0.1.%d" n))
  in
  let release n draft =
    `Assoc
      [
        ("tag_name", `String (tag n));
        ("draft", `Bool draft);
        ( "assets",
          `List
            ([
               asset (1000 + n) "manifest.json";
               asset ~digest:doc_030.bundle.bundle_sha256 (2000 + n)
                 (Printf.sprintf "digestif-relay-0.1.%d.tar.gz" n);
             ]
            @ List.mapi
                (fun i k ->
                  asset
                    (3000 + (10 * n) + i)
                    (Sign_next.signature_asset_name (Keys.public k)))
                (Option.value (List.assoc_opt n signed_by) ~default:[])) );
      ]
  in
  let listed =
    Yojson.Safe.to_string
      (`List
         (release published false :: List.map (fun n -> release n true) patches))
  in
  let uploaded = ref [] and deleted = ref [] and published_ = ref [] in
  let asked = ref 0 in
  let gh =
    with_attest @@ fun args ->
    match args with
    | [ "api"; "repos/o/r/releases?per_page=50" ] -> Ok listed
    | [ "api"; "-H"; _; a ] when contains ~sub:"releases/assets/1" a ->
        Ok (doc (int_of_string (Filename.basename a) - 1000))
    | [ "api"; "-H"; _; a ] when contains ~sub:"releases/assets/2" a -> Ok "1"
    | [ "release"; "upload"; t; _; "--repo"; "o/r"; "--clobber" ] ->
        uploaded := !uploaded @ [ t ];
        Ok ""
    | [ "release"; "delete"; t; "--repo"; "o/r"; "--yes" ] ->
        deleted := !deleted @ [ t ];
        Ok ""
    | _ -> Error ("unexpected gh " ^ String.concat " " args)
  in
  let git =
    fake_git
      ~shas:(List.map (fun n -> (tag n, tag n ^ "-sha")) (published :: patches))
      ~logs:[]
      ~paths:(List.map (fun n -> (tag n, "relay/src\n")) patches)
      ()
  in
  let relay : Sign_next.relay =
    {
      relay_versions = (fun () -> None);
      publish =
        (fun v ->
          published_ := !published_ @ [ Version.to_string v ];
          Ok ());
    }
  in
  let said = Buffer.create 1024 in
  let result =
    Sign_next.run ~gh ~git ~clone:(temp_dir ()) ~signers:founders
      ~config:
        {
          Sign_next.key_command = "unused";
          repo = "o/r";
          public_key = Option.map Keys.public public_key;
        }
      ~read_key:(fun () -> Ok (Keys.encode_secret key ^ "\n"))
      ~ask:(fun _ ->
        asked := !asked + 1;
        answer)
      ~say:(fun l -> Buffer.add_string said (l ^ "\n"))
      ~tmp:(temp_dir ()) ~relay ~timer:Timing.none ~listed:(listing gh)
  in
  (result, !uploaded, !deleted, !published_, !asked, Buffer.contents said)

let run_relays ?public_key ~published ~patches ~signed_by ~key answer =
  match
    run_relays_result ?public_key ~published ~patches ~signed_by ~key answer
  with
  | Ok (), uploaded, deleted, published, _, said ->
      (uploaded, deleted, published, said)
  | Error e, _, _, _, _, _ -> Alcotest.fail e

(* signer.json's public_key (ISS-54035): Mike signed relay-v0.1.12 and relay-v0.1.11, Roman signed
   relay-v0.1.7. With his key named, Mike is offered only relay-v0.1.7; without it he is offered all
   three, and s uploads only the one he has not signed. *)
let test_sign_next_leaves_out_my_drafts () =
  let patches = [ 7; 8; 9; 10; 11; 12 ] in
  let signed_by = [ (7, [ roman ]); (11, [ mike ]); (12, [ mike ]) ] in
  let uploaded, _, published, said =
    run_relays ~public_key:mike ~published:6 ~patches ~signed_by ~key:mike "s"
  in
  Alcotest.(check (list string))
    "only the draft Mike has not signed" [ "relay-v0.1.7" ] uploaded;
  Alcotest.(check (list string)) "which publishes" [ "0.1.7" ] published;
  Alcotest.(check bool)
    ("names what it left out: " ^ said)
    true
    (contains ~sub:"so not shown: relay-v0.1.12, relay-v0.1.11." said);
  Alcotest.(check bool)
    ("the drafts Mike signed are not shown: " ^ said)
    false
    (contains ~sub:"Digestif relay 0.1.12" said
    || contains ~sub:"also relay-v0.1.11" said);
  Alcotest.(check bool)
    ("one version, so the one-version question: " ^ said)
    true
    (contains ~sub:"Digestif relay 0.1.7, waiting" said);
  let uploaded, _, published, said =
    run_relays ~published:6 ~patches ~signed_by ~key:mike "s"
  in
  Alcotest.(check (list string))
    "without public_key, still only what Mike has not signed is uploaded"
    [ "relay-v0.1.7" ] uploaded;
  Alcotest.(check (list string)) "and it publishes" [ "0.1.7" ] published;
  Alcotest.(check bool)
    ("says the signed drafts were left alone: " ^ said)
    true
    (contains
       ~sub:
         "relay-v0.1.12 already carries your signature as Mike; nothing was \
          uploaded."
       said
    && contains ~sub:"relay-v0.1.11 already carries your signature" said);
  let result, uploaded, _, _, asked, said =
    run_relays_result ~public_key:mike ~published:10 ~patches:[ 11; 12 ]
      ~signed_by:[ (11, [ mike ]); (12, [ mike ]) ]
      ~key:mike "s"
  in
  Alcotest.(check bool)
    "nothing left is not an error" true (Result.is_ok result);
  Alcotest.(check (list string)) "nothing left: nothing uploaded" [] uploaded;
  Alcotest.(check int) "and no question" 0 asked;
  Alcotest.(check bool)
    ("says so: " ^ said) true
    (contains
       ~sub:"Every version waiting for you already carries your signature." said);
  let result, uploaded, _, _, _, _ =
    run_relays_result ~public_key:roman ~published:6 ~patches ~signed_by
      ~key:mike "s"
  in
  Alcotest.(check (list string))
    "a key that is not signer.json's public_key signs nothing" [] uploaded;
  match result with
  | Ok () -> Alcotest.fail "a key other than public_key signed"
  | Error e ->
      Alcotest.(check bool)
        ("names both keys: " ^ e) true
        (contains ~sub:(Keys.public mike) e
        && contains ~sub:(Keys.public roman) e)

let test_sign_relay_offers_newest_and_completable () =
  let patches = [ 7; 8; 9; 10; 11; 12 ] in
  let middle =
    [ "relay-v0.1.8"; "relay-v0.1.9"; "relay-v0.1.10"; "relay-v0.1.11" ]
  in
  let uploaded, deleted, published, said =
    run_relays ~published:6 ~patches ~signed_by:[ (7, [ roman ]) ] ~key:mike "s"
  in
  Alcotest.(check (list string))
    "Mike signs the newest and the one Roman signed"
    [ "relay-v0.1.12"; "relay-v0.1.7" ]
    uploaded;
  Alcotest.(check (list string))
    "Mike's signature publishes 0.1.7" [ "0.1.7" ] published;
  Alcotest.(check (list string)) "nothing is dropped" [] deleted;
  Alcotest.(check bool)
    ("the newest in full, the completable one in a line: " ^ said)
    true
    (contains ~sub:"Digestif relay 0.1.12, waiting" said
    && contains ~sub:"also relay-v0.1.7: signed by Roman" said);
  List.iter
    (fun t ->
      Alcotest.(check bool)
        (t ^ " is not shown: " ^ said)
        false (contains ~sub:t said))
    middle;
  let _, deleted, _, _ =
    run_relays ~published:6 ~patches ~signed_by:[ (7, [ roman ]) ] ~key:mike "d"
  in
  Alcotest.(check (list string))
    "d drops only what was offered"
    [ "relay-v0.1.12"; "relay-v0.1.7" ]
    deleted;
  (* The next run: 0.1.7 published, Mike signed 0.1.12, and Roman runs it. *)
  let uploaded, deleted, published, _ =
    run_relays ~published:7 ~patches:[ 8; 9; 10; 11; 12 ]
      ~signed_by:[ (12, [ mike ]) ]
      ~key:roman "s"
  in
  Alcotest.(check (list string))
    "Roman is offered only the newest" [ "relay-v0.1.12" ] uploaded;
  Alcotest.(check (list string)) "which publishes" [ "0.1.12" ] published;
  Alcotest.(check (list string))
    "and the skipped drafts are dropped" (List.rev middle) deleted

(* The tool's clone against real git: a source repository stands in for GitHub, the clone's
   https URL rewritten to it. git filters the commits by ci/relay-release-paths, magic and all. *)
let real_git ?source args =
  let args =
    match (source, args) with
    | Some src, "clone" :: rest ->
        "clone"
        :: List.map
             (fun a -> if a = "https://github.com/o/r.git" then src else a)
             rest
    | _ -> args
  in
  match Proc.run (Array.of_list ("git" :: args)) with
  | Ok { Proc.code = 0; stdout; _ } -> Ok stdout
  | Ok { Proc.code; stderr; _ } ->
      Error (Printf.sprintf "git exited %d: %s" code (String.trim stderr))
  | Error e -> Error e

let test_titles_from_clone () =
  let src = Filename.concat (temp_dir ()) "src" in
  let ok = function Ok s -> s | Error e -> Alcotest.fail e in
  let g args =
    ok
      (real_git
         ([
            "-C";
            src;
            "-c";
            "user.name=T";
            "-c";
            "user.email=t@example.com";
            "-c";
            "commit.gpgsign=false";
            "-c";
            "tag.gpgsign=false";
          ]
         @ args))
  in
  let commit title files =
    List.iter
      (fun (path, text) ->
        let full = Filename.concat src path in
        Sign_next.mkdir_p (Filename.dirname full);
        Out_channel.with_open_bin full (fun oc -> output_string oc text);
        ignore (g [ "add"; path ]))
      files;
    ignore (g [ "commit"; "--quiet"; "-m"; title ^ "\n\nA body line." ])
  in
  Sign_next.mkdir_p src;
  ignore (ok (real_git [ "init"; "--quiet"; src ]));
  commit "Start" [ ("relay/src/a.ts", "a") ];
  ignore (g [ "tag"; "relay-v0.2.0" ]);
  commit "Report the relay version"
    [ ("relay/src/read.ts", "r"); ("node/x.ml", "x") ];
  commit "A relay test only" [ ("relay/src/deep/read.test.ts", "t") ];
  commit "A node change" [ ("node/core/fold.ml", "f") ];
  commit "A ui change" [ ("ui/a/b/x.ts", "u") ];
  commit "A ui near miss" [ ("ui/ax.ts", "u") ];
  commit "Skipped" [ ("relay/src/skip/y.ts", "y") ];
  commit "Add the paths file"
    [
      ( "ci/relay-release-paths",
        "# c\n\
         relay/src\n\n\
         :(exclude,glob)relay/**/*.test.ts\n\
         :(glob)ui/**/x.ts\n\
         :!relay/src/skip\n" );
    ];
  ignore (g [ "tag"; "relay-v0.3.0" ]);
  let clone = Filename.concat (temp_dir ()) "update/o-r.git" in
  let said = ref [] in
  let git = real_git ~source:src in
  (match
     Sign_next.sync_clone ~git
       ~say:(fun l -> said := l :: !said)
       ~repo:"o/r" ~clone
   with
  | Ok () -> ()
  | Error e -> Alcotest.fail e);
  Alcotest.(check bool)
    "a bare clone" true
    (String.trim (ok (git [ "-C"; clone; "rev-parse"; "--is-bare-repository" ]))
    = "true");
  Alcotest.(check bool) "with every file" false (Sign_next.partial ~git ~clone);
  Alcotest.(check int) "one line while it clones" 1 (List.length !said);
  let sha tag = String.trim (g [ "rev-parse"; tag ]) in
  (match
     Sign_next.relay_titles ~git ~repo:"o/r" ~clone ~since:(Some "relay-v0.2.0")
       "relay-v0.3.0"
   with
  | Ok (titles, url, note) ->
      Alcotest.(check (list string))
        "only the commits touching a relay path, newest first"
        [ "A ui change"; "Report the relay version" ]
        titles;
      Alcotest.(check string)
        "the compare url"
        "https://github.com/o/r/compare/relay-v0.2.0...relay-v0.3.0" url;
      Alcotest.(check (option string)) "no note" None note
  | Error e -> Alcotest.fail e);
  (match
     Sign_next.relay_titles ~git ~repo:"o/r" ~clone ~since:None "relay-v0.2.0"
   with
  | Ok (titles, _, Some note) ->
      Alcotest.(check (list string))
        "a tag without the paths file shows every commit" [ "Start" ] titles;
      Alcotest.(check bool)
        ("and says so: " ^ note) true
        (contains ~sub:"every commit is shown" note)
  | Ok _ -> Alcotest.fail "a tag without the paths file said nothing"
  | Error e -> Alcotest.fail e);
  (match
     Sign_next.log_titles ~git ~repo:"o/r" ~clone ~since:(Some "relay-v0.2.0")
       "relay-v0.3.0"
   with
  | Ok (titles, _) ->
      Alcotest.(check int)
        "the node line reads every commit" 7 (List.length titles)
  | Error e -> Alcotest.fail e);
  Alcotest.(check (result string string))
    "a tag's commit, from the clone"
    (Ok (sha "relay-v0.3.0"))
    (Sign_next.tag_commit ~git ~clone "relay-v0.3.0");
  Alcotest.(check (result string string))
    "a file at a tag, from the clone" (Ok "r")
    (git [ "-C"; clone; "show"; "relay-v0.3.0:relay/src/read.ts" ]);
  (* A later run only fetches, and sees a tag cut since. *)
  commit "Later" [ ("relay/src/b.ts", "b") ];
  ignore (g [ "tag"; "relay-v0.3.1" ]);
  said := [];
  (match
     Sign_next.sync_clone ~git
       ~say:(fun l -> said := l :: !said)
       ~repo:"o/r" ~clone
   with
  | Ok () -> ()
  | Error e -> Alcotest.fail e);
  Alcotest.(check int) "nothing said when it only fetches" 0 (List.length !said);
  Alcotest.(check (result string string))
    "the new tag is fetched"
    (Ok (sha "relay-v0.3.1"))
    (Sign_next.tag_commit ~git ~clone "relay-v0.3.1");
  Alcotest.(check string)
    "the clone lives under ~/.digestif"
    (Filename.concat (Sys.getenv "HOME")
       ".digestif/update/digestif-ai-digestif.git")
    (Sign_next.clone_path "digestif-ai/digestif")

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
    (Result.is_error (Sign_next.config_of_string {|{ "key_command": " " }|}));
  (match Sign_next.load_config path with
  | Ok c -> Alcotest.(check (option string)) "no public_key" None c.public_key
  | Error e -> Alcotest.fail e);
  let key = Keys.public mike in
  (match
     Sign_next.config_of_string
       (Printf.sprintf {|{ "key_command": "x", "public_key": %S }|} key)
   with
  | Ok c ->
      Alcotest.(check (option string)) "the public_key" (Some key) c.public_key
  | Error e -> Alcotest.fail e);
  match
    Sign_next.config_of_string
      {|{ "key_command": "x", "public_key": "ed25519:nope" }|}
  with
  | Ok _ -> Alcotest.fail "a public_key that is not a key loaded"
  | Error e ->
      Alcotest.(check bool)
        ("names the field: " ^ e) true
        (contains ~sub:"public_key" e)

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
  put "behaviors/bin/read.ts" "#!/usr/bin/env node\n";
  Unix.chmod (Filename.concat dir "behaviors/bin/read.ts") 0o644;
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
       (In_channel.with_open_bin listing In_channel.input_lines));
  (* ISS-65250: a behavior program is executable in the archive whatever its checkout's mode. *)
  ignore
    (Sys.command
       (Printf.sprintf "tar -tvzf %s > %s" (Filename.quote out)
          (Filename.quote listing)));
  Alcotest.(check bool)
    "behaviors/bin/read.ts is executable in the archive" true
    (List.exists
       (fun l ->
         String.ends_with ~suffix:"behaviors/bin/read.ts" l
         && String.starts_with ~prefix:"-rwxr-xr-x" l)
       (In_channel.with_open_bin listing In_channel.input_lines))

(* A key command that fails ends the run once the signer answers s, in one line naming where the
   key goes, nothing signed (ISS-65276). *)
let test_sign_next_key_missing () =
  let f, gh = fake_gh () in
  let asked = ref 0 in
  let git =
    fake_git ~shas:[ ("v0.2.1", "abc123"); ("v0.2.0", "aaa000") ] ~logs:[] ()
  in
  let run key_command =
    Sign_next.run ~gh ~git ~clone:(temp_dir ()) ~signers:founders
      ~config:{ Sign_next.key_command; repo = "o/r"; public_key = None }
      ~read_key:(fun () ->
        incr f.keys_read;
        Error
          "the key command exited 1: cat: \
           /Users/m/Downloads/digestif-release.key: No such file or directory")
      ~ask:(fun _ ->
        incr asked;
        "s")
      ~say:ignore ~tmp:(temp_dir ()) ~relay:Sign_next.no_relay
      ~timer:Timing.none ~listed:(listing gh)
  in
  (match run "cat ~/Downloads/digestif-release.key" with
  | Ok () -> Alcotest.fail "a run with no key went on"
  | Error e ->
      List.iter
        (fun sub ->
          Alcotest.(check bool)
            ("says " ^ sub ^ ": " ^ e)
            true (contains ~sub e))
        [
          "Download the release key from 1Password to \
           ~/Downloads/digestif-release.key";
          "run the same command again";
          "nothing was signed";
        ];
      Alcotest.(check bool) "one line" false (String.contains e '\n'));
  (match run "op read 'op://x'" with
  | Ok () -> Alcotest.fail "a run with no key went on"
  | Error e ->
      Alcotest.(check bool)
        ("names the key command: " ^ e)
        true
        (contains ~sub:"key_command print your release key" e));
  Alcotest.(check int) "each run asked before it read the key" 2 !asked;
  Alcotest.(check bool) "nothing uploaded" true (!(f.uploaded) = None)

(* A key command that prints something that is not a key is the same precondition. *)
let test_sign_next_key_garbage () =
  let f, gh = fake_gh () in
  let git =
    fake_git ~shas:[ ("v0.2.1", "abc123"); ("v0.2.0", "aaa000") ] ~logs:[] ()
  in
  match
    Sign_next.run ~gh ~git ~clone:(temp_dir ()) ~signers:founders
      ~config:
        {
          Sign_next.key_command = "cat /k/digestif-release.key";
          repo = "o/r";
          public_key = None;
        }
      ~read_key:(fun () -> Ok "not a key\n")
      ~ask:(fun _ -> "s")
      ~say:ignore ~tmp:(temp_dir ()) ~relay:Sign_next.no_relay
      ~timer:Timing.none ~listed:(listing gh)
  with
  | Ok () -> Alcotest.fail "a run with no key went on"
  | Error e ->
      Alcotest.(check bool)
        ("names the file: " ^ e) true
        (contains ~sub:"from 1Password to /k/digestif-release.key" e);
      Alcotest.(check bool) "nothing uploaded" true (!(f.uploaded) = None)

(* sign --next with a fake gh and clone, the timing log at [timer], the key and the answer counted
   by the caller. *)
let run_next_with ~timer ~read_key ~ask =
  let f, gh = fake_gh () in
  let git =
    fake_git
      ~shas:[ ("v0.2.1", "abc123"); ("v0.2.0", "aaa000") ]
      ~logs:[ ("v0.2.0..v0.2.1", "Fix the digest\n") ]
      ()
  in
  let result =
    Sign_next.run ~gh ~git ~clone:(temp_dir ()) ~signers:founders
      ~config:
        { Sign_next.key_command = "unused"; repo = "o/r"; public_key = None }
      ~read_key ~ask ~say:ignore ~tmp:(temp_dir ()) ~relay:Sign_next.no_relay
      ~timer ~listed:(listing gh)
  in
  (f, result)

(* The key is read only once the signer answers s: everything is shown, and the question asked,
   with the key unread (DIG-148). *)
let test_sign_next_key_after_answer () =
  let keys = ref 0 and keys_when_asked = ref (-1) in
  let f, result =
    run_next_with ~timer:Timing.none
      ~read_key:(fun () ->
        incr keys;
        Ok (Keys.encode_secret mike ^ "\n"))
      ~ask:(fun _ ->
        keys_when_asked := !keys;
        "s")
  in
  (match result with Ok () -> () | Error e -> Alcotest.fail e);
  Alcotest.(check int)
    "no key read when the question is asked" 0 !keys_when_asked;
  Alcotest.(check int) "read once after the s" 1 !keys;
  Alcotest.(check bool) "and signed" true (!(f.uploaded) <> None)

(* GitHub is asked for the manifest and the upload and nothing else: a tag's commit and the run
   link never cost a request (DIG-148). *)
let test_sign_next_github_only_for_releases () =
  let f, result, _ = run_next "s" in
  (match result with Ok () -> () | Error e -> Alcotest.fail e);
  let download id =
    [
      "api";
      "-H";
      "Accept: application/octet-stream";
      "repos/o/r/releases/assets/" ^ id;
    ]
  in
  let attest file =
    [
      "attestation";
      "verify";
      file;
      "--repo";
      "o/r";
      "--signer-workflow";
      "o/r/.github/workflows/release.yml";
      "--source-ref";
      "refs/tags/v0.2.1";
      "--source-digest";
      "abc123";
      "--deny-self-hosted-runners";
      "--format";
      "json";
    ]
  in
  Alcotest.(check (list (list string)))
    "every gh call: the listing, the draft's files, and each file's attestation"
    (List.sort compare
       [
         [ "api"; "repos/o/r/releases?per_page=50" ];
         download "21";
         download "25";
         attest "v0.2.1/0.2.1";
         attest "v0.2.1/manifest.json";
       ])
    (List.sort compare
       (List.filter_map
          (function
            | "release" :: _ -> None
            | "attestation" :: "verify" :: path :: rest ->
                Some
                  ("attestation" :: "verify"
                  :: Filename.concat
                       (Filename.basename (Filename.dirname path))
                       (Filename.basename path)
                  :: rest)
            | c -> Some c)
          !(f.calls)))

(* Every step of a run is a line of the timing log: run id, step, seconds (DIG-148). *)
let test_sign_next_timing_log () =
  let path = Filename.concat (temp_dir ()) "sign-next-timings.log" in
  let timer = Timing.create ~path () in
  let _, result =
    run_next_with ~timer
      ~read_key:(fun () -> Ok (Keys.encode_secret mike ^ "\n"))
      ~ask:(fun _ -> "s")
  in
  (match result with Ok () -> () | Error e -> Alcotest.fail e);
  let lines = In_channel.with_open_bin path In_channel.input_lines in
  let rows = List.map (String.split_on_char '\t') lines in
  List.iter
    (fun row ->
      match row with
      | [ run; _; seconds ] ->
          Alcotest.(check string) "one run id" timer.run run;
          Alcotest.(check bool)
            ("seconds: " ^ seconds) true
            (Option.is_some (float_of_string_opt seconds))
      | _ -> Alcotest.fail ("not run, step, seconds: " ^ String.concat "|" row))
    rows;
  let steps = List.map (fun r -> List.nth r 1) rows in
  List.iter
    (fun step ->
      Alcotest.(check bool)
        ("logs " ^ step ^ ": " ^ String.concat ", " steps)
        true (List.mem step steps))
    [
      "clone";
      "manifest v0.2.1";
      "manifests";
      "show v0.2.1";
      "until-question";
      "answer";
      "key";
      "sign v0.2.1";
    ];
  Alcotest.(check bool)
    "the key is read after the answer" true
    (let index s =
       let rec go i = function
         | [] -> -1
         | x :: rest -> if x = s then i else go (i + 1) rest
       in
       go 0 steps
     in
     index "answer" < index "key")

(* Calls made at once: each waits until the other has started, so they could only both finish by
   running together; the answers come back in the order asked, and an exception is raised again. *)
let test_parallel_map () =
  let m = Mutex.create () and started = ref 0 in
  let wait_for_both x =
    Mutex.protect m (fun () -> incr started);
    let deadline = Unix.gettimeofday () +. 10. in
    while
      Mutex.protect m (fun () -> !started) < 2
      && Unix.gettimeofday () < deadline
    do
      Thread.yield ()
    done;
    (x, Mutex.protect m (fun () -> !started))
  in
  Alcotest.(check (list (pair int int)))
    "both ran at once, answered in order"
    [ (1, 2); (2, 2) ]
    (Parallel.map wait_for_both [ 1; 2 ]);
  Alcotest.check_raises "an exception is raised again" (Failure "two")
    (fun () ->
      ignore
        (Parallel.map
           (fun x -> if x = 2 then failwith "two" else x)
           [ 1; 2; 3 ]))

(* A partial clone an earlier digestif-update made (--filter=blob:none) is cloned again in full,
   once, so no file read fetches from GitHub (DIG-148). *)
let test_partial_clone_recloned () =
  let src = Filename.concat (temp_dir ()) "src" in
  let ok = function Ok s -> s | Error e -> Alcotest.fail e in
  let g args =
    ok
      (real_git
         ([
            "-C";
            src;
            "-c";
            "user.name=T";
            "-c";
            "user.email=t@example.com";
            "-c";
            "commit.gpgsign=false";
            "-c";
            "tag.gpgsign=false";
          ]
         @ args))
  in
  ignore (ok (real_git [ "init"; "--quiet"; src ]));
  Out_channel.with_open_bin (Filename.concat src "a.txt") (fun oc ->
      output_string oc "a");
  ignore (g [ "add"; "a.txt" ]);
  ignore (g [ "commit"; "--quiet"; "-m"; "Start" ]);
  ignore (g [ "tag"; "v0.1.0" ]);
  ignore (g [ "config"; "uploadpack.allowfilter"; "true" ]);
  let clone = Filename.concat (temp_dir ()) "update/o-r.git" in
  Sign_next.mkdir_p (Filename.dirname clone);
  ignore
    (ok
       (real_git
          [
            "clone";
            "--bare";
            "--quiet";
            "--filter=blob:none";
            "file://" ^ src;
            clone;
          ]));
  let git = real_git ~source:src in
  Alcotest.(check bool)
    "the old clone is partial" true
    (Sign_next.partial ~git ~clone);
  let said = ref [] in
  (match
     Sign_next.sync_clone ~git
       ~say:(fun l -> said := l :: !said)
       ~repo:"o/r" ~clone
   with
  | Ok () -> ()
  | Error e -> Alcotest.fail e);
  Alcotest.(check bool) "it is full now" false (Sign_next.partial ~git ~clone);
  Alcotest.(check bool)
    ("says so: " ^ String.concat "; " !said)
    true
    (List.exists (contains ~sub:"cloning o/r again in full") !said);
  Alcotest.(check (result string string))
    "the file reads from the clone" (Ok "a")
    (git [ "-C"; clone; "show"; "v0.1.0:a.txt" ])

(* OUT OF DATE: sign --next says when a newer node release is published than the running
   digestif-update, and how it reaches the signer; it replaces nothing and never stops the run. *)

let out_of_date_gh () =
  let listing =
    Yojson.Safe.to_string
      (`List
         [
           `Assoc
             [
               ("tag_name", `String "v0.4.0");
               ("draft", `Bool true);
               ("assets", `List []);
             ];
           `Assoc
             [
               ("tag_name", `String "v0.3.0");
               ("draft", `Bool false);
               ("assets", `List []);
             ];
           `Assoc
             [
               ("tag_name", `String "v0.2.0");
               ("draft", `Bool false);
               ("assets", `List []);
             ];
         ])
  in
  let calls = ref [] in
  let gh args =
    calls := !calls @ [ args ];
    match args with
    | [ "api"; "repos/o/r/releases?per_page=50" ] -> Ok listing
    | _ -> Error ("unexpected gh " ^ String.concat " " args)
  in
  (calls, gh)

let empty_channel : Feed.t =
  {
    releases = [];
    revocations = [];
    recalls = [];
    signer_sets = [];
    problems = [];
  }

let run_out_of_date ?(running = "0.2.0") ?(channel = Ok empty_channel) ~gh self
    =
  let said = Buffer.create 128 in
  Out_of_date.run
    ~listed:(gh [ "api"; Sign_next.releases_path "o/r" ])
    ~signers:founders ~channel ~running:(v running) ~self
    ~say:(fun l -> Buffer.add_string said (l ^ "\n"))
    ();
  Buffer.contents said

(* A node's own binary: <data dir>/releases/<version>/bin/digestif-update, reached through the
   link on PATH. *)
let node_tool () =
  let data = temp_dir () in
  let bin = Filename.concat data "releases/0.2.0/bin" in
  Sign_next.mkdir_p bin;
  let tool = Filename.concat bin "digestif-update" in
  Out_channel.with_open_bin tool (fun oc -> Out_channel.output_string oc "");
  let link = Filename.concat (temp_dir ()) "digestif-update" in
  Unix.symlink tool link;
  link

let held_tool () =
  let self = Filename.concat (temp_dir ()) "digestif-update-darwin-arm64" in
  Out_channel.with_open_bin self (fun oc -> Out_channel.output_string oc "");
  self

let test_out_of_date_in_a_node () =
  let _, gh = out_of_date_gh () in
  let said = run_out_of_date ~gh (node_tool ()) in
  List.iter
    (fun sub ->
      Alcotest.(check bool)
        ("says " ^ sub ^ ": " ^ said)
        true (contains ~sub said))
    [ "v0.3.0 is published"; "is 0.2.0"; "digestif update apply" ];
  Alcotest.(check bool)
    ("never offers the draft: " ^ said)
    false
    (contains ~sub:"v0.4.0" said)

let test_out_of_date_held () =
  let _, gh = out_of_date_gh () in
  let self = held_tool () in
  let said = run_out_of_date ~gh self in
  List.iter
    (fun sub ->
      Alcotest.(check bool)
        ("says " ^ sub ^ ": " ^ said)
        true (contains ~sub said))
    [
      "v0.3.0 is published";
      self;
      "no node keeps current";
      "https://digestif.io/install.sh";
    ];
  Alcotest.(check string)
    "the held file is unchanged" ""
    (In_channel.with_open_bin self In_channel.input_all)

let test_out_of_date_quiet () =
  let calls, gh = out_of_date_gh () in
  let self = held_tool () in
  Alcotest.(check string)
    "current: nothing said" ""
    (run_out_of_date ~running:"0.3.0" ~gh self);
  Alcotest.(check string)
    "an untagged build: nothing said" ""
    (run_out_of_date ~running:"0.0.0" ~gh self);
  Alcotest.(check string)
    "GitHub not answering: nothing said" ""
    (run_out_of_date ~gh:(fun _ -> Error "gh api exited 1: HTTP 502") self);
  Alcotest.(check string)
    "the channel not answering: nothing said" ""
    (run_out_of_date ~channel:(Error "index.json: curl exited 7") ~gh self);
  Alcotest.(check bool)
    "reads nothing but the release list" true
    (List.for_all
       (fun c -> c = [ "api"; "repos/o/r/releases?per_page=50" ])
       !calls)

(* A published version a current signer recalled is never offered; a recall signed by no current
   signer counts for nothing, and a revoked signer's recall counts for nothing either. *)
let test_out_of_date_skips_recalled () =
  let _, gh = out_of_date_gh () in
  let self = node_tool () in
  let said =
    run_out_of_date
      ~channel:
        (Ok { empty_channel with recalls = [ recall ~by:[ roman ] "0.3.0" ] })
      ~gh self
  in
  Alcotest.(check bool)
    ("says why: " ^ said) true
    (contains ~sub:"Digestif 0.3.0 was recalled by Roman" said);
  Alcotest.(check bool)
    ("does not offer it: " ^ said)
    false
    (contains ~sub:"v0.3.0 is published" said);
  let said =
    run_out_of_date
      ~channel:
        (Ok { empty_channel with recalls = [ recall ~by:[ mallory ] "0.3.0" ] })
      ~gh self
  in
  Alcotest.(check bool)
    ("an outsider's recall is ignored: " ^ said)
    true
    (contains ~sub:"v0.3.0 is published" said);
  let said =
    run_out_of_date
      ~channel:
        (Ok
           {
             empty_channel with
             recalls = [ recall ~by:[ roman ] "0.3.0" ];
             revocations = [ revocation ~by:[ mike ] roman ];
           })
      ~gh self
  in
  Alcotest.(check bool)
    ("a revoked signer's recall is ignored: " ^ said)
    true
    (contains ~sub:"v0.3.0 is published" said)

(* digestif-update approve (docs/releases.md, Approvals): a fake node API holding one approval list
   and the folded set, recording every POST. *)

let ap_set = [ ("Mike", mike); ("Roman", roman) ]

let ap_signers_json ?(revoked = []) set =
  `Assoc
    [
      ( "signers",
        `List
          (List.map
             (fun (n, s) ->
               `Assoc
                 [
                   ("key", `String (Keys.public s));
                   ("name", `String n);
                   ("revoked", `Bool (List.mem n revoked));
                 ])
             set) );
      ("halted", `Bool (revoked <> []));
    ]

let ap_member name s =
  `Assoc
    [
      ("identity", `String ("ed25519:identity-" ^ name));
      ("name", `String name);
      ("agent_name", `String (name ^ "'s agent"));
    ]
  |> fun j -> (j, s)

let ap_approval ?(state = "waiting") ?member ?document ?added ?removed
    ?(waiting = []) ~id ~kind ~rows () =
  let opt k = function None -> [] | Some v -> [ (k, v) ] in
  `Assoc
    ([
       ("id", `String id);
       ("kind", `String kind);
       ("state", `String state);
       ("started_by", fst (ap_member "Mike" mike));
       ("created_at", `String "2026-11-14T15:00:00.000Z");
       ("expires_at", `String "2026-11-21T15:00:00.000Z");
       ("waiting_on", `List (List.map (fun n -> fst (ap_member n mike)) waiting));
       ("signed_count", `Int (List.length (List.filter snd rows)));
       ("needed_count", `Int (List.length rows));
       ( "signers",
         `List
           (List.map
              (fun (k, signed) ->
                `Assoc [ ("key", `String k); ("signed", `Bool signed) ])
              rows) );
     ]
    @ opt "member" (Option.map (fun n -> fst (ap_member n mike)) member)
    @ opt "document" (Option.map (fun d -> `String (B64url.encode d)) document)
    @ opt "added_key" (Option.map (fun k -> `String k) added)
    @ opt "removed_key" (Option.map (fun k -> `String k) removed))

let admission_bytes =
  {|{"format":"digestif-admission-v0","circle":"sha256:root","created_at":"2026-11-14T15:00:00.000Z","guest":{"name":"Priya Raman","email":"priya@raman.dev"},"role":"member","invite_key":"ed25519:invite","subject":"Join the Sunday circle on Digestif","body":"Hi Priya,\n[install command]\n[expiry]"}|}

let fake_node ?(signers = ap_signers_json ap_set) ?(post_status = 200) approvals
    =
  let posts = ref [] in
  let api : Approve.api =
   fun ~meth ~path ~body ->
    match (meth, path) with
    | "GET", "/api/v0/signers" -> Ok (200, signers)
    | "GET", p when String.starts_with ~prefix:"/api/v0/approvals" p ->
        let waiting_only = String.ends_with ~suffix:"state=waiting" p in
        Ok
          ( 200,
            `List
              (List.filter
                 (fun a ->
                   (not waiting_only)
                   || Release.field "state" a = Some (`String "waiting"))
                 approvals) )
    | "POST", p ->
        posts := (p, Option.get body) :: !posts;
        let answer =
          match approvals with
          | a :: _ when post_status < 300 -> a
          | _ ->
              `List
                [ `Assoc [ ("code", `String "x"); ("message", `String "no") ] ]
        in
        Ok (post_status, answer)
    | _ -> Ok (404, `Null)
  in
  (api, posts)

let said () =
  let lines = ref [] in
  ((fun l -> lines := l :: !lines), fun () -> List.rev !lines)

let body_string k j =
  match Release.field k j with Some (`String s) -> Some s | _ -> None

let test_approve_signs_an_invite () =
  let a =
    ap_approval ~id:"sha256:inv" ~kind:"invite" ~document:admission_bytes
      ~waiting:[ "Roman" ]
      ~rows:[ (Keys.public mike, true); (Keys.public roman, false) ]
      ()
  in
  let api, posts = fake_node [ a ] in
  let say, lines = said () in
  (match
     Approve.sign ~api ~secret:roman ~ask:(fun _ -> "y") ~say "sha256:inv"
   with
  | Ok () -> ()
  | Error e -> Alcotest.fail e);
  Alcotest.(check bool)
    "shows the guest and the email" true
    (List.mem "Invite Priya Raman <priya@raman.dev> as member" (lines ())
    && List.mem "Subject: Join the Sunday circle on Digestif" (lines ()));
  match !posts with
  | [ (path, body) ] ->
      Alcotest.(check string)
        "the signatures route" "/api/v0/approvals/sha256:inv/signatures" path;
      Alcotest.(check (option string))
        "the key"
        (Some (Keys.public roman))
        (body_string "key" body);
      Alcotest.(check (option string))
        "no document" None
        (body_string "document" body);
      Alcotest.(check bool)
        "verifies over the admission domain" true
        (Keys.verify ~pub:(Keys.public roman)
           ~signature:(Option.get (body_string "signature" body))
           (Approval.admission_domain ^ admission_bytes));
      Alcotest.(check bool)
        "never the secret" false
        (let b = Yojson.Safe.to_string body in
         let sec = Keys.encode_secret roman in
         let n = String.length sec in
         let rec has i =
           i + n <= String.length b && (String.sub b i n = sec || has (i + 1))
         in
         has 0)
  | _ -> Alcotest.fail "expected one POST"

let test_approve_declined_at_the_question () =
  let a =
    ap_approval ~id:"sha256:inv" ~kind:"invite" ~document:admission_bytes
      ~rows:[ (Keys.public roman, false) ]
      ()
  in
  let api, posts = fake_node [ a ] in
  let say, _ = said () in
  ignore (Approve.sign ~api ~secret:roman ~ask:(fun _ -> "") ~say "sha256:inv");
  Alcotest.(check int) "nothing posted" 0 (List.length !posts)

let expect_error what = function
  | Ok () -> Alcotest.fail (what ^ ": expected an error")
  | Error e -> e

let contains ~sub s =
  let n = String.length sub in
  let rec go i =
    i + n <= String.length s && (String.sub s i n = sub || go (i + 1))
  in
  go 0

let test_approve_refuses () =
  let say, _ = said () in
  let yes _ = "y" in
  (* already signed *)
  let a =
    ap_approval ~id:"sha256:a" ~kind:"invite" ~document:admission_bytes
      ~rows:[ (Keys.public roman, true) ]
      ()
  in
  let api, posts = fake_node [ a ] in
  let e =
    expect_error "signed"
      (Approve.sign ~api ~secret:roman ~ask:yes ~say "sha256:a")
  in
  Alcotest.(check bool) "already signed" true (contains ~sub:"already signed" e);
  (* a key it does not need *)
  let e =
    expect_error "outsider"
      (Approve.sign ~api ~secret:mallory ~ask:yes ~say "sha256:a")
  in
  Alcotest.(check bool)
    "not needed" true
    (contains ~sub:"does not need your key" e);
  (* ended *)
  let ended =
    ap_approval ~state:"declined" ~id:"sha256:d" ~kind:"invite"
      ~document:admission_bytes
      ~rows:[ (Keys.public roman, false) ]
      ()
  in
  let api2, posts2 = fake_node [ ended ] in
  let e =
    expect_error "ended"
      (Approve.sign ~api:api2 ~secret:roman ~ask:yes ~say "sha256:d")
  in
  Alcotest.(check bool) "declined" true (contains ~sub:"is declined" e);
  (* unknown *)
  let e =
    expect_error "unknown"
      (Approve.sign ~api ~secret:roman ~ask:yes ~say "sha256:zz")
  in
  Alcotest.(check bool) "unknown" true (contains ~sub:"no approval sha256:zz" e);
  Alcotest.(check int)
    "nothing posted" 0
    (List.length !posts + List.length !posts2)

let promotion ?document () =
  ap_approval ~id:"sha256:p" ~kind:"promotion" ~member:"Carol" ?document
    ~waiting:[ "Carol" ]
    ~rows:[ (Keys.public mike, false); (Keys.public roman, false) ]
    ()

let test_approve_promotion_first_signature () =
  let api, posts = fake_node [ promotion () ] in
  let say, _ = said () in
  (match
     Approve.sign ~api ~secret:carol ~ask:(fun _ -> "yes") ~say "sha256:p"
   with
  | Ok () -> ()
  | Error e -> Alcotest.fail e);
  match !posts with
  | [ (_, body) ] -> (
      let doc =
        match B64url.decode (Option.get (body_string "document" body)) with
        | Ok d -> d
        | Error e -> Alcotest.fail e
      in
      Alcotest.(check bool)
        "signed over the signers domain" true
        (Keys.verify ~pub:(Keys.public carol)
           ~signature:(Option.get (body_string "signature" body))
           (Approval.signers_domain ^ doc));
      match Trust_root.signers_of_string doc with
      | Ok set ->
          Alcotest.(check (list string))
            "the current set plus the member's key"
            [ Keys.public mike; Keys.public roman; Keys.public carol ]
            (List.map (fun (s : Release.signer) -> s.key) set);
          Alcotest.(check string)
            "under the member's name" "Carol" (List.nth set 2).name
      | Error e -> Alcotest.fail e)
  | _ -> Alcotest.fail "expected one POST"

let test_approve_admin_waits_on_promoted_member () =
  let api, posts = fake_node [ promotion () ] in
  let say, _ = said () in
  let e =
    expect_error "admin first"
      (Approve.sign ~api ~secret:roman ~ask:(fun _ -> "y") ~say "sha256:p")
  in
  Alcotest.(check bool)
    "Waiting on Carol" true
    (contains ~sub:"Waiting on Carol" e);
  Alcotest.(check int) "nothing posted" 0 (List.length !posts)

let set_doc keys =
  Approve.signers_document ~created_at:"2026-11-14T15:00:00.000Z"
    (List.map (fun (n, s) -> { Release.name = n; key = Keys.public s }) keys)

let test_approve_promotion_admin_signs_completed () =
  let doc = set_doc [ ("Mike", mike); ("Roman", roman); ("Carol", carol) ] in
  let a =
    ap_approval ~id:"sha256:p" ~kind:"promotion" ~member:"Carol" ~document:doc
      ~added:(Keys.public carol) ~waiting:[ "Roman" ]
      ~rows:
        [
          (Keys.public mike, true);
          (Keys.public roman, false);
          (Keys.public carol, true);
        ]
      ()
  in
  let api, posts = fake_node [ a ] in
  let say, lines = said () in
  (match
     Approve.sign ~api ~secret:roman ~ask:(fun _ -> "y") ~say "sha256:p"
   with
  | Ok () -> ()
  | Error e -> Alcotest.fail e);
  Alcotest.(check bool)
    "marks the added key" true
    (List.mem (Printf.sprintf "  + Carol  %s" (Keys.public carol)) (lines ()));
  match !posts with
  | [ (_, body) ] ->
      Alcotest.(check (option string))
        "no document" None
        (body_string "document" body)
  | _ -> Alcotest.fail "expected one POST"

let test_approve_refuses_a_document_not_its_kind () =
  (* Filed as a promotion, but the set also drops Roman. *)
  let doc = set_doc [ ("Mike", mike); ("Carol", carol) ] in
  let a =
    ap_approval ~id:"sha256:p" ~kind:"promotion" ~member:"Carol" ~document:doc
      ~rows:[ (Keys.public mike, false) ]
      ()
  in
  let api, posts = fake_node [ a ] in
  let say, _ = said () in
  let e =
    expect_error "not its kind"
      (Approve.sign ~api ~secret:mike ~ask:(fun _ -> "y") ~say "sha256:p")
  in
  Alcotest.(check bool)
    "names the kind" true
    (contains ~sub:"not the promotion" e);
  Alcotest.(check int) "nothing posted" 0 (List.length !posts)

let test_approve_refuses_duplicate_admission_member () =
  let doc = with_last_member {|"invite_key":"ed25519:other"|} admission_bytes in
  let a =
    ap_approval ~id:"sha256:inv" ~kind:"invite" ~document:doc
      ~waiting:[ "Roman" ]
      ~rows:[ (Keys.public mike, true); (Keys.public roman, false) ]
      ()
  in
  let api, posts = fake_node [ a ] in
  let say, _ = said () in
  let e =
    expect_error "a second invite_key"
      (Approve.sign ~api ~secret:roman ~ask:(fun _ -> "y") ~say "sha256:inv")
  in
  Alcotest.(check bool)
    ("names the member: " ^ e) true
    (contains ~sub:"\"invite_key\" twice" e);
  Alcotest.(check int) "nothing posted" 0 (List.length !posts)

let test_approve_refuses_non_canonical_admission () =
  (* Every member once, but not in the order the node renders them. *)
  let doc =
    match Yojson.Safe.from_string admission_bytes with
    | `Assoc fields -> Yojson.Safe.to_string (`Assoc (List.rev fields))
    | _ -> Alcotest.fail "admission_bytes is an object"
  in
  let a =
    ap_approval ~id:"sha256:inv" ~kind:"invite" ~document:doc
      ~waiting:[ "Roman" ]
      ~rows:[ (Keys.public mike, true); (Keys.public roman, false) ]
      ()
  in
  let api, posts = fake_node [ a ] in
  let say, _ = said () in
  let e =
    expect_error "reordered"
      (Approve.sign ~api ~secret:roman ~ask:(fun _ -> "y") ~say "sha256:inv")
  in
  Alcotest.(check bool)
    ("says so: " ^ e) true
    (contains ~sub:"not in its canonical form" e);
  Alcotest.(check int) "nothing posted" 0 (List.length !posts)

let test_approve_refuses_duplicate_signers_member () =
  let doc = set_doc [ ("Mike", mike); ("Roman", roman); ("Carol", carol) ] in
  let other =
    Printf.sprintf
      {|"signers": [ { "name": "Mike", "key": %S }, { "name": "Mallory", "key": %S } ]|}
      (Keys.public mike) (Keys.public mallory)
  in
  let a =
    ap_approval ~id:"sha256:p" ~kind:"promotion" ~member:"Carol"
      ~document:(with_last_member other doc)
      ~added:(Keys.public carol) ~waiting:[ "Roman" ]
      ~rows:
        [
          (Keys.public mike, true);
          (Keys.public roman, false);
          (Keys.public carol, true);
        ]
      ()
  in
  let api, posts = fake_node [ a ] in
  let say, _ = said () in
  let e =
    expect_error "a second signers"
      (Approve.sign ~api ~secret:roman ~ask:(fun _ -> "y") ~say "sha256:p")
  in
  Alcotest.(check bool)
    ("names the member: " ^ e) true
    (contains ~sub:"\"signers\" twice" e);
  Alcotest.(check int) "nothing posted" 0 (List.length !posts)

let test_approve_accepts_compact_signers () =
  (* A removal's document is the node's compact rendering (Approval.signers_document). *)
  let doc =
    Approval.signers_document ~created_at:"2026-11-14T15:00:00.000Z"
      (List.map
         (fun (n, k) -> { Approval.name = n; key = Keys.public k })
         [ ("Mike", mike); ("Roman", roman) ])
  in
  match Approve.canonical_signers doc with
  | Ok l -> Alcotest.(check int) "two signers" 2 (List.length l)
  | Error e -> Alcotest.fail e

let test_approve_replacement_first_signature () =
  let a =
    ap_approval ~id:"sha256:r" ~kind:"replacement" ~member:"Roman"
      ~added:(Keys.public roman2) ~removed:(Keys.public roman)
      ~waiting:[ "Roman" ]
      ~rows:[ (Keys.public mike, false); (Keys.public roman, false) ]
      ()
  in
  let api, posts =
    fake_node ~signers:(ap_signers_json ~revoked:[ "Roman" ] ap_set) [ a ]
  in
  let say, _ = said () in
  (* The old key cannot sign first. *)
  let e =
    expect_error "old first"
      (Approve.sign ~api ~secret:roman ~ask:(fun _ -> "y") ~say "sha256:r")
  in
  Alcotest.(check bool)
    "waits on the new key" true
    (contains ~sub:"Waiting on Roman" e);
  (match
     Approve.sign ~api ~secret:roman2 ~ask:(fun _ -> "y") ~say "sha256:r"
   with
  | Ok () -> ()
  | Error e -> Alcotest.fail e);
  match !posts with
  | [ (_, body) ] -> (
      let doc =
        Result.get_ok (B64url.decode (Option.get (body_string "document" body)))
      in
      match Trust_root.signers_of_string doc with
      | Ok set ->
          Alcotest.(check (list string))
            "the revoked key moved to the new one"
            [ Keys.public mike; Keys.public roman2 ]
            (List.map (fun (s : Release.signer) -> s.key) set)
      | Error e -> Alcotest.fail e)
  | _ -> Alcotest.fail "expected one POST"

let test_approve_lists_what_waits_on_this_key () =
  let mine =
    ap_approval ~id:"sha256:mine" ~kind:"invite" ~document:admission_bytes
      ~rows:[ (Keys.public roman, false) ]
      ()
  in
  let signed =
    ap_approval ~id:"sha256:done" ~kind:"invite" ~document:admission_bytes
      ~rows:[ (Keys.public roman, true) ]
      ()
  in
  let api, _ = fake_node [ mine; signed; promotion () ] in
  let say, lines = said () in
  (match Approve.list ~api ~me:(Keys.public roman) ~say with
  | Ok () -> ()
  | Error e -> Alcotest.fail e);
  Alcotest.(check bool)
    "lists the one waiting" true
    (List.mem "  digestif-update approve sha256:mine" (lines ()));
  Alcotest.(check bool)
    "not the signed one or the promotion" false
    (List.exists
       (fun l -> contains ~sub:"sha256:done" l || contains ~sub:"sha256:p" l)
       (lines ()));
  (* The promoted member sees the promotion. *)
  let say, lines = said () in
  ignore (Approve.list ~api ~me:(Keys.public carol) ~say);
  Alcotest.(check bool)
    "the member's promotion" true
    (List.mem "  digestif-update approve sha256:p" (lines ()))

let test_signers_propose () =
  let filed =
    ap_approval ~id:"sha256:r" ~kind:"replacement" ~member:"Roman"
      ~added:(Keys.public roman2) ~removed:(Keys.public roman)
      ~rows:[ (Keys.public mike, false) ]
      ()
  in
  let api, posts = fake_node ~post_status:201 [ filed ] in
  let say, lines = said () in
  (match
     Approve.propose_replacement ~api ~say ~old:(Keys.public roman)
       ~new_:(Keys.public roman2)
   with
  | Ok () -> ()
  | Error e -> Alcotest.fail e);
  Alcotest.(check bool)
    "prints the command" true
    (List.mem "  digestif-update approve sha256:r" (lines ()));
  (match !posts with
  | [ ("/api/v0/approvals", body) ] ->
      Alcotest.(check (option string))
        "kind" (Some "replacement") (body_string "kind" body);
      Alcotest.(check (option string))
        "removed"
        (Some (Keys.public roman))
        (body_string "removed_key" body);
      Alcotest.(check (option string))
        "added"
        (Some (Keys.public roman2))
        (body_string "added_key" body)
  | _ -> Alcotest.fail "expected one POST to /api/v0/approvals");
  let _ =
    expect_error "same key"
      (Approve.propose_replacement ~api ~say ~old:(Keys.public roman)
         ~new_:(Keys.public roman))
  in
  let _ =
    expect_error "not a key"
      (Approve.propose_replacement ~api ~say ~old:"roman"
         ~new_:(Keys.public roman2))
  in
  Alcotest.(check int) "one POST" 1 (List.length !posts)

let test_approve_needs_a_node () =
  let dir = Filename.temp_dir "digestif-approve" "" in
  match
    Approve.with_node ~transport:Relay_client.curl ~data_dir:dir (fun _ ->
        Ok ())
  with
  | Ok () -> Alcotest.fail "expected no node"
  | Error e ->
      Alcotest.(check bool)
        "says no node" true
        (contains ~sub:"no node runs here" e)

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
          t "a chain in any order" test_chain_in_any_order;
          t "a manifest names no signers" test_manifest_signers_refused;
          t "the channel's signers/" test_signers_channel;
          t "the admission halt" test_signer_halt;
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
          t "an adopted signer set never widens" test_adopted_set_never_widens;
          t "an unreconciled load keeps the stored set"
            test_unreconciled_load_keeps_the_stored_set;
          t "strikes refuse on the last" test_strikes_refuse_on_the_last;
          t "state updates are serialized" test_state_updates_are_serialized;
          t "sign names a key file it cannot read" test_sign_missing_key;
          t "verify both signed" test_verify_both;
          t "verify one missing" test_verify_one_missing;
          t "verify drops other signatures" test_verify_drops_others;
          t "verify refuses another version" test_verify_wrong_version;
          t "shipped build names two" test_shipped_build_names_two;
          t "hook follows current" test_hook_follows_current;
          t "status problems" test_status_problems;
          t "an unpack failure is retried" test_unpack_failure_is_retried;
          t "try again clears a refusal" test_retry_clears_refusal;
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
          t "--sign signs without asking" test_sign_next_sign_flag;
          t "drops" test_sign_next_drops;
          t "leaves" test_sign_next_leaves;
          t "a key that is not there" test_sign_next_key_missing;
          t "a key command printing no key" test_sign_next_key_garbage;
          t "the key is read after the answer" test_sign_next_key_after_answer;
          t "GitHub only for releases" test_sign_next_github_only_for_releases;
          t "the timing log" test_sign_next_timing_log;
          t "calls made at once" test_parallel_map;
          t "a partial clone is cloned again in full"
            test_partial_clone_recloned;
          t "out of date in a node" test_out_of_date_in_a_node;
          t "out of date, held outside a node" test_out_of_date_held;
          t "out of date says nothing otherwise" test_out_of_date_quiet;
          t "out of date skips a recalled version"
            test_out_of_date_skips_recalled;
          t "outsider key" test_sign_next_outsider_key;
          t "wrong version" test_sign_next_wrong_version;
          t "a member twice" test_sign_next_refuses_duplicate_member;
          t "not canonical" test_sign_next_refuses_non_canonical;
          t "shows who signed" test_sign_next_shows_who_signed;
          t "waiting" test_sign_next_waiting;
          t "offered" test_sign_next_offered;
          t "refuses what its build did not attest"
            test_sign_next_refuses_unattested;
          t "signs only what its build attested"
            test_sign_next_signs_only_attested;
          t "relay: refuses a migration that differs"
            test_sign_relay_refuses_migration;
          t "attestation: the certificate is read back"
            test_attestation_runs_of_json;
          t "leaves out my drafts" test_sign_next_leaves_out_my_drafts;
          t "offers the newest and what one signature completes"
            test_sign_next_offers_newest_and_completable;
          t "relay: offers the newest and what one signature completes"
            test_sign_relay_offers_newest_and_completable;
          t "commit titles from the tool's clone" test_titles_from_clone;
          t "relay: shows" test_sign_relay_shows;
          t "relay: a bundle twice" test_sign_relay_refuses_duplicate_bundle;
          t "relay: signs and waits" test_sign_relay_signs_and_waits;
          t "relay: completes and publishes"
            test_sign_relay_completes_and_publishes;
          t "relay: outsider" test_sign_relay_outsider;
          t "both lines" test_sign_both_lines;
          t "a draft on an unknown line" test_sign_unread_draft;
          t "relay-publish" test_relay_publish;
          t "relay-publish waits" test_relay_publish_waits;
          t "relay-publish other manifest" test_relay_publish_other_manifest;
          t "relay-publish held line" test_relay_held_line;
          t "relay version of circle" test_relay_version_of_circle;
          t "signer.json" test_signer_config;
          t "where the key is read" test_key_reader;
          t "archive carries digestif-update" test_bundle_carries_update_binary;
        ] );
      ( "commands on PATH",
        [
          t "follow good" test_cli_links_follow_good;
          t "leave the member's own" test_cli_links_leave_the_members_own;
          t "wait for good" test_cli_links_wait_for_good;
          t "after an update" test_cli_links_after_an_update;
          t "the standard node's" test_cli_links_are_the_standard_nodes;
        ] );
      ( "supervisor",
        [
          t "awake clock" test_awake_clock;
          t "crash on start rolls back" test_crash_on_start_rolls_back;
          t "healthy is kept" test_healthy_is_kept;
          t "unhealthy times out" test_unhealthy_times_out;
          t "unhealthy on every try is refused"
            test_unhealthy_every_try_is_refused;
          t "an environment exit on trial is a strike"
            test_environment_exit_on_trial_is_a_strike;
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
          t "only abnormal exits count" test_only_abnormal_exits_count;
          t "a crash moves back once" test_crash_moves_back_once;
        ] );
      ( "schedule",
        [
          t "due" test_due;
          t "report once" test_report_once;
          t "switches" test_schedule_switches;
          t "reports refusal" test_schedule_reports_refusal;
          t "report drop keeps later lines" test_report_drop_keeps_later_lines;
          t "reports failure" test_schedule_reports_failure;
          t "a success clears the failure" test_schedule_failure_clears;
          t "curl's exit names its cause" test_curl_cause;
          t "an https channel names no local path"
            test_resolve_refuses_local_path_under_https;
          t "an https index naming a local path"
            test_https_index_naming_a_local_path;
          t "every read is bounded" test_fetch_is_bounded;
          t "the archive is bounded by its signed size"
            test_archive_bounded_by_signed_size;
        ] );
      ( "approve",
        [
          t "signs an invite" test_approve_signs_an_invite;
          t "no at the question" test_approve_declined_at_the_question;
          t "refuses" test_approve_refuses;
          t "a promotion's first signature"
            test_approve_promotion_first_signature;
          t "an admin waits on the promoted member"
            test_approve_admin_waits_on_promoted_member;
          t "an admin signs the completed set"
            test_approve_promotion_admin_signs_completed;
          t "a document not its kind"
            test_approve_refuses_a_document_not_its_kind;
          t "an admission member twice"
            test_approve_refuses_duplicate_admission_member;
          t "an admission not canonical"
            test_approve_refuses_non_canonical_admission;
          t "a signers member twice"
            test_approve_refuses_duplicate_signers_member;
          t "a removal's compact signer set"
            test_approve_accepts_compact_signers;
          t "a replacement's first signature"
            test_approve_replacement_first_signature;
          t "lists what waits on this key"
            test_approve_lists_what_waits_on_this_key;
          t "signers propose" test_signers_propose;
          t "needs a node" test_approve_needs_a_node;
        ] );
    ]
