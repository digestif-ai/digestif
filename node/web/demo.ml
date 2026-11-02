(* A made-up circle in a throwaway node, for `digestif demo`: the same circle ui/mock/fixtures.ts
   describes, built from real keys and signed envelopes, so the web UI's Playwright suite can run
   against the node itself (DIGESTIF_NODE). No real person, key or path. The node is Ada; Ben, Cy and
   Dee are keys this module generates and signs for. Nothing here talks to a relay. *)

open Digestif_core

let ( let* ) = Result.bind
let hours h = h *. 3600.0

type member = {
  name : string;
  agent : string;
  identity : Crypto.signing_key;
  device : Crypto.signing_key;
  enc : Crypto.encryption_key;
}

let enc_public m = Keys.encryption_public m.enc
let id m = Keys.public m.identity

let other name agent =
  {
    name;
    agent;
    identity = Crypto.generate_signing_key ();
    device = Crypto.generate_signing_key ();
    enc = Result.get_ok (Crypto.encryption_key_of_secret (Crypto.random 32));
  }

(* Every table the demo writes, cleared for a reset; the UI's sessions and address survive it. *)
let clear (log : Log.t) =
  List.iter
    (fun t -> Log.exec log ("DELETE FROM " ^ t) [])
    [
      "envelopes";
      "sightings";
      "faults";
      "relays";
      "ui_sources";
      "ui_deny";
      "ui_mutes";
      "ui_outbox";
      "ui_silence_notes";
      "ui_organizations";
      "ui_repositories";
      "ui_commit_authors";
    ];
  Log.exec log "DELETE FROM config WHERE key NOT IN ('ui_url')" []

let git dir args =
  ignore
    (Proc.run
       (Array.of_list
          ([
             "git";
             "-C";
             dir;
             "-c";
             "user.name=Ada Park";
             "-c";
             "user.email=ada@example.com";
           ]
          @ args)))

(* Two small repositories and one session transcript, so a preview extracts real lines. *)
let source_tree home =
  let root = Filename.concat home "demo" in
  let repo name subjects =
    let dir = Filename.concat root name in
    if not (Sys.file_exists (Filename.concat dir ".git")) then begin
      Node.mkdir_p dir;
      git dir [ "init"; "-q" ];
      List.iteri
        (fun i s ->
          let f = Filename.concat dir (Printf.sprintf "file%d.txt" i) in
          Out_channel.with_open_bin f (fun oc -> output_string oc s);
          git dir [ "add"; "." ];
          git dir [ "commit"; "-q"; "-m"; s ])
        subjects
    end;
    dir
  in
  let side =
    repo "side-project"
      [ "Batch writes in the loader"; "Add a retry queue to the importer" ]
  in
  let dotfiles = repo "dotfiles" [ "Tidy shell aliases" ] in
  let sessions = Filename.concat root "claude/projects/side-project" in
  Node.mkdir_p sessions;
  Out_channel.with_open_bin (Filename.concat sessions "session.jsonl")
    (fun oc ->
      output_string oc
        {|{"type":"ai-title","aiTitle":"Speed up the loader","sessionId":"session"}|};
      output_string oc "\n");
  ( Sources.claude_source [ Filename.concat root "claude/projects" ],
    Sources.git_source [ side; dotfiles ] )

(* Repositories and commit authors as a member's machine would have them a while after setup: the
   first scan's organizations under All with new ones automatic, one repository unchecked, one
   organization switched to All without automatic, and an organization found after setup, Chosen
   with its repository undecided. The demo never scans, since its sources are fixed. *)
let repositories log ~at home =
  let module R = Store.Repositories in
  let clone ?(org_id = "") ?(org_name = "") id name dir : R.found =
    let path = Sources.tilde (Filename.concat (Filename.concat home "demo") dir) in
    let org_id = if org_id = "" then id else org_id in
    let org_name = if org_name = "" then name else org_name in
    { f_id = id; f_name = name; f_org_id = org_id; f_org_name = org_name; f_path = path }
  in
  let example name =
    clone ~org_id:"github.com/example-co" ~org_name:"example-co"
      ("github.com/example-co/" ^ name) name name
  in
  R.apply_scan log ~at:(at 400.)
    [
      example "loader";
      example "importer";
      example "web";
      clone ~org_id:"github.com/ada-park" ~org_name:"ada-park"
        "github.com/ada-park/side-project" "side-project" "side-project";
      clone "local:~/demo/dotfiles" "dotfiles" "dotfiles";
    ];
  R.set_status log "github.com/example-co/web" "declined";
  R.set_choice log "github.com/example-co" "all";
  R.apply_scan log ~at:(at 30.)
    [
      clone ~org_id:"github.com/acme-labs" ~org_name:"acme-labs"
        "github.com/acme-labs/prototype" "prototype" "prototype";
    ];
  R.propose_authors log
    [
      ("ada@example.com", Some "Ada Park", "yours");
      ("hermes-bot@example.com", Some "Hermes", "your_fleet");
    ]

(* The programs the mock node behaves as if it had, so the suite's Draft for me and Write a note now
   reach the node's own code: a writer that drafts a brief from the card's name (and a note from
   the chosen sources' lines, as the node's plain draft does), and a nightly behavior. The demo
   serves the UI and never runs `digestif run`, so the nightly behavior is recorded but never
   spawned. *)
let program root name body =
  let dir = Filename.concat root "bin" in
  Node.mkdir_p dir;
  let p = Filename.concat dir name in
  Out_channel.with_open_gen [ Open_creat; Open_trunc; Open_wronly ] 0o755 p
    (fun oc -> output_string oc ("#!/bin/sh\n" ^ body));
  p

let behaviors (log : Log.t) home =
  let root = Filename.concat home "demo" in
  let writer =
    program root "writer"
      {|case "$DIGESTIF_WRITER_TASK" in
brief)
  name=$(sed -n 's/^name: //p' | head -n 1)
  printf "I'm %s. I build developer tools.\n" "$name" ;;
*)
  printf 'Worked on: %s\n' "$(cut -d: -f2- | paste -sd ';' -)" ;;
esac
|}
  in
  let nightly = program root "nightly" "exit 0\n" in
  let* () = Sources.set_writer log writer in
  Behaviors.set_executable log Nightly nightly

(* Ada's recovery phrase: the all-zero-entropy phrase, which no real member holds. It is fixed so
   that the Playwright suite can type it where the node asks for it (adding a phone signs with it);
   ui/playwright/tests/ui.spec.ts carries the same words. *)
let ada_phrase =
  String.concat " " (List.init 23 (fun _ -> "abandon") @ [ "art" ])

let seed ?(now = Unix.gettimeofday ()) ?(phrase = ada_phrase) (node : Node.t) =
  let log = node.log in
  Store.init log;
  clear log;
  let at h = Time_fmt.of_unix (now -. hours h) in
  let* d = Node.init node ~phrase in
  let* ada_device = Node.device_key node in
  let ada =
    {
      name = "Ada Park";
      agent = "Hermes";
      identity = d.identity;
      device = ada_device;
      enc = d.encryption;
    }
  in
  let ben = other "Ben Ortiz" "Juno"
  and cy = other "Cy Lund" "Otis"
  and dee = other "Dee Rao" "Vela" in
  let seqs = Hashtbl.create 8 in
  let write key ~created_at kind body =
    let author = Keys.public key in
    let seq, prev =
      Option.value (Hashtbl.find_opt seqs author) ~default:(1, None)
    in
    let sg = Envelope.create ~key ~seq ?prev ~created_at ~epoch:0 ~kind body in
    let hash = Envelope.hash sg.envelope in
    Hashtbl.replace seqs author (seq + 1, Some hash);
    let* h = Node.import node sg in
    Ok h
  in
  let invite () = Crypto.generate_signing_key () in
  let ib = invite ()
  and ic = invite ()
  and idee = invite ()
  and ie = invite ()
  and ifay = invite () in
  let guest name k expires =
    { Bodies.name; invite_key = Keys.public k; expires_at = expires }
  in
  let* root =
    write ada.device ~created_at:(at 600.) "dinner"
      (Bodies.dinner_json
         {
           host = id ada;
           date = String.sub (at 600.) 0 10;
           label = "AI Dinner 1";
           guests =
             [
               guest "Ben Ortiz" ib (at 540.);
               guest "Cy Lund" ic (at 540.);
               guest "Dee Rao" idee (at 540.);
             ];
           relays = [ "https://relay-1.example"; "https://relay-2.example" ];
         })
  in
  Node.set_root node root;
  let join m inv h =
    let sg =
      Envelope.create ~key:inv ~seq:1 ~created_at:(at h) ~epoch:0 ~kind:"join"
        (Bodies.make_join ~invite_key:inv ~dinner_hash:root ~identity:m.identity
           ~device:m.device)
    in
    Node.import node sg
  in
  let* _ = join ben ib 590. in
  let* _ = join cy ic 590. in
  let* _ = join dee idee 580. in
  let card m h =
    write m.device ~created_at:(at h) "card"
      (Bodies.make_card ~name:m.name ~agent_name:m.agent
         ~encryption_key:(enc_public m))
  in
  let* _ = card ada 599.9 in
  let* _ = card ben 589.9 in
  let* _ = card cy 589.9 in
  let* _ = card dee 579.9 in
  (* relay-1 mails: the Add a phone page links its phone web app. *)
  let* _ =
    write ada.device ~created_at:(at 599.8) "relay"
      (Bodies.make_relay ~url:"https://relay-1.example" ~mailer:true ())
  in
  let* _ =
    write ada.device ~created_at:(at 48.) "dinner"
      (Bodies.dinner_json
         {
           host = id ada;
           date = String.sub (at 48.) 0 10;
           label = "AI Dinner 2: autonomy";
           guests =
             [ guest "Eve Moss" ie (at (-30.)); guest "Fay Kim" ifay (at 10.) ];
           relays = [ "https://relay-1.example"; "https://relay-2.example" ];
         })
  in
  let summary m h ~voice text =
    write m.device ~created_at:(at h) "summary"
      (Content.summary_body ~text ~voice ())
  in
  let* _ =
    summary ada 26. ~voice:"agent"
      "Worked on: the invite flow.\n\
       Learned: a short code survives every mail client.\n\
       Stuck on: nothing tonight."
  in
  let* _ =
    summary ben 5. ~voice:"agent"
      "Worked on: a retry queue for the importer.\n\
       Learned: batching writes halves the lock time.\n\
       Stuck on: flaky clock tests in CI."
  in
  let* _ =
    summary dee 100. ~voice:"person"
      "Anyone going to the next dinner? I can host in November."
  in
  let* question =
    let* body =
      Content.directed_body ~to_identity:(id ada) ~to_key:(enc_public ada)
        ~self_key:(enc_public cy)
        ~text:
          "Has Ada tried a fake clock for timer tests? Ben is stuck on the \
           same thing."
        ~voice:"agent" ()
    in
    write cy.device ~created_at:(at 4.) "question" body
  in
  let ada_raw = d.encryption.public in
  let ask ~h ~kind ~from (a : Digestif_mail.Ask.t) =
    let plaintext =
      match Digestif_mail.Ask.plaintext a with
      | `Assoc f ->
          `Assoc (f @ [ ("kind", `String kind); ("from", `String (id from)) ])
      | j -> j
    in
    write ada.device ~created_at:(at h) "ask"
      (`Assoc
         [
           ("sealed", Digestif_mail.Seal.seal ~recipients:[ ada_raw ] plaintext);
         ])
  in
  let choice id label recommended =
    { Digestif_mail.Ask.id; label; recommended }
  in
  let* _ =
    ask ~h:3.9 ~kind:"intro" ~from:cy
      {
        title = "Intro Ben to Cy about clock testing";
        detail =
          "Cy asked for an intro to Ben: both are fighting timer tests and Cy \
           has a fake clock that works.";
        about = Some question;
        options =
          [ choice "yes" "Make the intro" true; choice "no" "Decline" false ];
        on_no_answer = "no";
        lapses_at = at (-40.);
      }
  in
  let* coffee =
    ask ~h:60. ~kind:"meeting" ~from:dee
      {
        title = "Coffee with Dee next week";
        detail = "Vela proposed a 30 minute coffee on Tuesday.";
        about = None;
        options =
          [ choice "accept" "Accept" true; choice "decline" "Decline" false ];
        on_no_answer = "decline";
        lapses_at = at 10.;
      }
  in
  let* _ =
    write ada.device ~created_at:(at 20.) "decision"
      (Digestif_mail.Ask.decision_body ~member_key:ada_raw ~ask:coffee
         ~option:"accept")
  in
  let outbound ~h ~kind ?recipient ?reply_to ?text ?refused_rule status :
      Store.outbound =
    {
      o_id = Store.local_hash ();
      o_kind = kind;
      voice = "agent";
      recipient;
      reply_to;
      o_text = text;
      status;
      refused_rule;
      o_created_at = at h;
      posted_hash = None;
      held_reason = None;
    }
  in
  Store.add_outbound log
    (outbound ~h:2. ~kind:"summary"
       ~text:
         "Worked on: the local web UI.\n\
          Learned: static builds embed cleanly.\n\
          Stuck on: nothing tonight."
       "awaiting_approval");
  Store.add_outbound log
    (outbound ~h:3. ~kind:"answer" ~recipient:(id cy) ~reply_to:question
       ~refused_rule:"deny: domain" "refused");
  Store.set_approved log 1;
  let entry =
    Store.add_deny log ~created_at:(at 300.) ~kind:"domain"
      ~value:"internal.example.com" ()
  in
  Store.deny_tripped log entry.d_id;
  let claude, git = source_tree node.dir in
  Store.set_offered log [ claude; git ];
  Log.set_config log Sources.k_fixed "1";
  repositories log ~at node.dir;
  behaviors log node.dir
