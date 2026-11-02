(* The invite flow on real nodes over the in-process relays: the host invites, a guest joins with
   the bootstrap read, the host's sync shows an expected join and asks about an unexpected one, and
   a revoke answer signed with the phrase's identity key revokes the stranger. *)

open Digestif_core
open Digestif_invite

let ok = function Ok v -> v | Error e -> Alcotest.fail e

let tmpdir () =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "digestif-invite-%d-%s" (Unix.getpid ())
       (B64url.encode (Crypto.random 6)))

let new_node () = Node.open_ ~keystore:(Keystore.memory ()) (tmpdir ())
let urls = [ "https://a.test"; "https://b.test" ]

let guests =
  [
    {
      Dinner.name = "Roman Cherkasov";
      email = "roman@example.com";
      platform = None;
    };
    {
      Dinner.name = "Phong Nguyen";
      email = "phong@example.com";
      platform = None;
    };
  ]

let identity_of phrase = Keys.public (ok (Phrase.derive phrase)).identity

let host_circle () =
  let host = new_node () and host_phrase = Phrase.generate () in
  ignore (ok (Node.init host ~phrase:host_phrase));
  let inv =
    ok
      (Invite_node.invite host ~date:"2026-10-27" ~label:"AI Dinner 2"
         ~relays:urls guests)
  in
  Alcotest.(check (option string))
    "a founding dinner is the root" (Some inv.dinner_hash) (Node.root host);
  let relays =
    List.map (fun url -> Fake_relay.create ~url ~root:inv.dinner_hash) urls
  in
  let net = Fake_relay.network relays in
  let report, _ = ok (Invite_node.sync ~transport:net host) in
  List.iter
    (fun (r : Sync.relay_report) ->
      Alcotest.(check int) ("the dinner reached " ^ r.relay) 1 r.pushed)
    report.relays;
  (host, host_phrase, inv, relays, net)

let guest_joins net (inv : Invite_node.invited) n =
  let guest = new_node () and phrase = Phrase.generate () in
  let code =
    ok
      (Invite_code.parse
         (Invite_code.to_url (List.nth inv.dinner.invites n).code))
  in
  let w = ok (Invite_node.join ~transport:net guest ~code ~phrase) in
  (guest, phrase, w)

let flow () =
  let host, host_phrase, inv, relays, net = host_circle () in
  let phong = (List.nth inv.dinner.invites 1).invite_key in
  ignore (ok (Invite_node.expect host ~guest:"phong nguyen"));
  let roman, roman_phrase, w = guest_joins net inv 0 in
  Alcotest.(check string)
    "the join names the dinner" inv.dinner_hash w.dinner_hash;
  List.iter
    (fun (relay, r) ->
      match r with
      | Ok (_ : Relay_client.receipt) -> ()
      | Error e ->
          Alcotest.failf "%s refused the join: %s" relay
            (Relay_client.error_to_string e))
    w.appended;
  Alcotest.(check int)
    "appended to every relay the dinner lists" 2 (List.length w.appended);
  Alcotest.(check (option string))
    "the guest learns the root from a relay that admitted it"
    (Some inv.dinner_hash) (Node.root roman);
  Alcotest.(check (list string))
    "the guest reads every relay the dinner lists" urls
    (List.sort compare
       (List.map (fun (r : Log.relay_row) -> r.url) (Log.relays roman.log)));
  ignore (ok (Invite_node.sync ~transport:net roman));
  Alcotest.(check bool)
    "the guest's own node admits it" true
    (Fold.find (Node.fold roman) (identity_of roman_phrase) <> None);
  let _, phong_phrase, _ = guest_joins net inv 1 in
  let _, seen = ok (Invite_node.sync ~transport:net host) in
  let outcomes = List.map (fun (s : Invite_node.seen) -> s.outcome) seen in
  Alcotest.(check bool)
    "the expected join is shown" true
    (List.exists
       (function Host_watch.Shown r -> r.invite_key = phong | _ -> false)
       outcomes);
  let key = "join:" ^ (List.hd inv.dinner.invites).invite_key in
  (match Asks.list host.log with
  | [ a ] ->
      Alcotest.(check string) "one ask, for the unexpected join" key a.key;
      Alcotest.(check (option string))
        "about the identity that joined"
        (Some (identity_of roman_phrase))
        a.about;
      Alcotest.(check string)
        "an unanswered ask revokes" "revoke" a.on_no_answer;
      Alcotest.(check bool)
        "not lapsed yet" false
        (Asks.lapsed ~now:(Time_fmt.now ()) a)
  | l -> Alcotest.failf "%d asks, want 1" (List.length l));
  let _, again = ok (Invite_node.sync ~transport:net host) in
  Alcotest.(check int)
    "a join seen once is not asked twice" 0 (List.length again);
  Alcotest.(check bool)
    "a wrong answer is refused" true
    (Result.is_error
       (Invite_node.answer host ~key ~choice:"maybe" ~identity:(fun () ->
            Alcotest.fail "phrase asked for")));
  let revoke =
    ok
      (Invite_node.answer host ~key ~choice:"revoke" ~identity:(fun () ->
           Node.identity_from_phrase host host_phrase))
  in
  Alcotest.(check bool) "the revoke is written" true (revoke <> None);
  Alcotest.(check int)
    "the ask is answered" 0
    (List.length (Asks.list host.log));
  let report, _ = ok (Invite_node.sync ~transport:net host) in
  List.iter
    (fun (r : Sync.relay_report) ->
      Alcotest.(check (option string)) ("pushed to " ^ r.relay) None r.error)
    report.relays;
  List.iter
    (fun (r : Fake_relay.t) ->
      match Fold.find (Fake_relay.fold r) (identity_of roman_phrase) with
      | Some k ->
          Alcotest.(check bool)
            (r.url ^ " revoked the stranger")
            true (k.revoked_by <> None)
      | None -> Alcotest.fail "the identity is unknown to the relay")
    relays;
  (match Fold.find (Node.fold host) (identity_of phong_phrase) with
  | Some k ->
      Alcotest.(check bool) "the expected guest stays" true (k.revoked_by = None)
  | None -> Alcotest.fail "the expected guest is not admitted");
  match ok (Host_watch.load host.dir) with
  | ledger ->
      Alcotest.(check bool)
        "the ledger records the revoke" true
        (List.exists
           (fun (r : Host_watch.record) ->
             match r.state with Revoked _ -> true | _ -> false)
           ledger)

let refused () =
  let _, _, inv, relays, net = host_circle () in
  let stranger_code =
    { Invite_code.relay = "https://a.test"; secret = Crypto.random 16 }
  in
  let n = new_node () in
  (match
     Invite_node.join ~transport:net n ~code:stranger_code
       ~phrase:(Phrase.generate ())
   with
  | Ok _ -> Alcotest.fail "a code no dinner names joined"
  | Error _ -> ());
  ignore (guest_joins net inv 0);
  let n2 = new_node () in
  let code = (List.hd inv.dinner.invites).code in
  (match
     Invite_node.join ~transport:net n2 ~code ~phrase:(Phrase.generate ())
   with
  | Ok _ -> Alcotest.fail "a spent invite joined again"
  | Error _ -> ());
  ignore relays

let asks_store () =
  let n = new_node () in
  let ask lapses_at detail =
    {
      Asks.key = "join:ed25519:x";
      title = "Confirm";
      detail;
      about = Some "ed25519:id";
      options =
        [
          { id = "confirm"; label = "Confirm" };
          { id = "revoke"; label = "Revoke" };
        ];
      recommended = "revoke";
      on_no_answer = "revoke";
      lapses_at;
      raised_at = "";
      answer = None;
      answered_at = None;
      envelope = None;
      answered_via = None;
    }
  in
  ok (Asks.raise_ n.log (ask "2026-10-31T00:00:00.000Z" "first"));
  ok (Asks.record_answer n.log ~key:"join:ed25519:x" "confirm");
  Alcotest.(check int)
    "answered asks leave the open list" 0
    (List.length (Asks.list n.log));
  ok (Asks.raise_ n.log (ask "2026-10-31T00:00:00.000Z" "second identity"));
  (match Asks.list n.log with
  | [ a ] ->
      Alcotest.(check string)
        "re-raised under its key" "second identity" a.detail;
      Alcotest.(check bool)
        "lapsed after its time" true
        (Asks.lapsed ~now:"2026-11-01T00:00:00.000Z" a)
  | _ -> Alcotest.fail "a re-raised ask did not reopen");
  Alcotest.(check bool)
    "an on_no_answer outside the options is refused" true
    (Result.is_error
       (Asks.raise_ n.log
          { (ask "2026-10-31T00:00:00.000Z" "x") with on_no_answer = "keep" }))

let url_handler () =
  let d =
    Url_handler.desktop_entry ~exe:"/opt/digestif/bin/digestif"
      ~dir:"/home/x/.local/share/digestif"
  in
  Alcotest.(check bool)
    "the desktop entry handles digestif: links" true
    (Astring_contains.contains d "MimeType=x-scheme-handler/digestif;"
    && Astring_contains.contains d
         "Exec=/opt/digestif/bin/digestif --data-dir \
          /home/x/.local/share/digestif join %u");
  Alcotest.(check string)
    "quotes a path with a space" "\"/a b\""
    (Url_handler.desktop_quote "/a b");
  let s = Url_handler.applescript ~exe:"/a b/digestif" ~dir:"/d" in
  Alcotest.(check bool)
    "the applet runs digestif join on the URL" true
    (Astring_contains.contains s "on open location theURL"
    && Astring_contains.contains s "quoted form of \"/a b/digestif\""
    && Astring_contains.contains s "quoted form of \"join\"")

(* ---- setup in the terminal (docs/design.md, Install) ---- *)

(* A terminal that answers from a script and keeps everything said. *)
type script = {
  mutable answers : string list;  (** each ask, secret and key, in order *)
  mutable said : string list;  (** newest first *)
  mutable copied : string list;  (** newest first *)
}

let scripted answers =
  let s = { answers; said = []; copied = [] } in
  let next p =
    s.said <- p :: s.said;
    match s.answers with
    | [] -> None
    | a :: rest ->
        s.answers <- rest;
        Some a
  in
  let io =
    {
      Terminal.say = (fun l -> s.said <- l :: s.said);
      ask = next;
      secret = next;
      key = (fun p -> Option.map (fun a -> a.[0]) (next p));
      copy =
        (fun t ->
          s.copied <- t :: s.copied;
          true);
    }
  in
  (s, io)

let said s sub = List.exists (fun l -> Astring_contains.contains l sub) s.said

let claude =
  { Agents.kind = Claude_code; name = "Claude Code"; path = "/x/claude" }

let codex = { Agents.kind = Codex; name = "Codex"; path = "/x/codex" }
let other = { Agents.kind = Other; name = "my-agent"; path = "/x/my-agent" }

type calls = {
  mutable phrases : int;
  mutable services : int;
  mutable chats : string list;
  mutable agent : Agents.t option;
}

(* A setup env over a real guest node and the in-process relays, with fake agents. *)
let setup_env ?(machine_ok = true) ?(works = [ claude; codex ])
    ?(found = [ claude; codex ]) ?(chat = fun _ -> Ok 0) ~net ~code
    (node : Node.t) io =
  let calls = { phrases = 0; services = 0; chats = []; agent = None } in
  let phrase = Phrase.generate () in
  let env =
    {
      Setup.io;
      macos = true;
      exe = "/home/x/.local/bin/digestif";
      machine =
        (fun () ->
          [
            {
              Machine_check.label = "Keychain";
              what = "login keychain";
              ok = machine_ok;
              detail =
                (if machine_ok then "stores and reads a key"
                 else "The login keychain is locked");
            };
          ]);
      find_agents = (fun () -> found);
      of_path =
        (fun p ->
          match
            List.find_opt
              (fun (a : Agents.t) -> a.path = p)
              [ claude; codex; other ]
          with
          | Some a -> Ok a
          | None -> Error (p ^ " is not a program on this machine"));
      check_agent =
        (fun a ->
          if List.memq a works then Agents.Works
          else Agents.Fails "does not answer (exit 1): not signed in");
      saved_agent = (fun () -> calls.agent);
      save_agent = (fun a -> calls.agent <- Some a);
      new_phrase =
        (fun () ->
          calls.phrases <- calls.phrases + 1;
          phrase);
      stored_join = (fun () -> Join_store.load node.dir);
      prepare =
        (fun ~phrase -> Invite_node.prepare ~transport:net node ~code ~phrase);
      post = (fun s -> Invite_node.post ~transport:net node s);
      install_service =
        (fun () ->
          calls.services <- calls.services + 1;
          Ok ());
      start_chat =
        (fun a ->
          calls.chats <- a.name :: calls.chats;
          chat a);
    }
  in
  (env, calls, phrase)

let wrong_word phrase n w =
  String.concat " "
    (List.mapi
       (fun i x -> if i = n then w else x)
       (String.split_on_char ' ' phrase))

let invite_code (inv : Invite_node.invited) n =
  ok
    (Invite_code.parse
       (Invite_code.to_url (List.nth inv.dinner.invites n).code))

let setup_joins () =
  let _host, _, inv, relays, net = host_circle () in
  let code = invite_code inv 0 in
  let guest = new_node () in
  (* Two agents work: the member picks 2. Then c copies, a wrong paste names the word. *)
  let s, io = scripted [ "2"; "c"; ""; "" ] in
  let env, calls, phrase = setup_env ~net ~code guest io in
  let pasted_wrong = wrong_word phrase 14 "tender" in
  s.answers <- [ "2"; "c"; pasted_wrong; phrase ];
  ok (Setup.join env ~invite_key:(Invite_code.invite_public_key code));
  Alcotest.(check bool) "the machine is checked" true (said s "Keychain");
  Alcotest.(check bool)
    "both agents are listed" true
    (said s "1  Claude Code" && said s "2  Codex");
  Alcotest.(check bool)
    "the wrong word is named" true
    (said s "Word 15 is not tender. Paste it again:");
  Alcotest.(check (list string))
    "the phrase is copied, then cleared once it matches" [ ""; phrase ] s.copied;
  Alcotest.(check bool)
    "the way back is printed with its full path" true
    (said s
       "If this window closes, run /home/x/.local/bin/digestif setup to \
        continue.");
  Alcotest.(check bool)
    "joined as the host named them" true
    (said s "Joined the circle as Roman Cherkasov.");
  Alcotest.(check (list string))
    "the chosen agent is started" [ "Codex" ] calls.chats;
  Alcotest.(check int) "the service is installed" 1 calls.services;
  let stored = Option.get (ok (Join_store.load guest.dir)) in
  Alcotest.(check bool) "the stored join is posted" true stored.posted;
  List.iter
    (fun r ->
      Alcotest.(check bool)
        "every relay holds the join" true
        (List.exists
           (fun (e : Fake_relay.stored) ->
             e.hash = Envelope.hash stored.join.envelope)
           r.Fake_relay.items))
    relays;
  (* Running the command again posts the same join, shows no phrase, and starts the agent. *)
  let s2, io2 = scripted [] in
  let env2, calls2, _ = setup_env ~net ~code guest io2 in
  calls2.agent <- Some codex;
  ok (Setup.join env2 ~invite_key:(Invite_code.invite_public_key code));
  Alcotest.(check int) "no new phrase" 0 calls2.phrases;
  Alcotest.(check bool) "no agent check" false (said s2 "Coding agents");
  Alcotest.(check (list string))
    "the agent starts again" [ "Codex" ] calls2.chats;
  List.iter
    (fun r ->
      Alcotest.(check int)
        "the relay holds one join, not two" 1
        (List.length
           (List.filter
              (fun (e : Fake_relay.stored) ->
                e.signed.envelope.Envelope.kind = "join")
              r.Fake_relay.items)))
    relays

let setup_stops_unspent () =
  let _host, _, inv, _relays, net = host_circle () in
  let code = invite_code inv 0 in
  let key = Invite_code.invite_public_key code in
  (* The machine cannot hold keys: nothing past the machine check runs. *)
  let guest = new_node () in
  let s, io = scripted [] in
  let env, calls, _ = setup_env ~machine_ok:false ~net ~code guest io in
  (match Setup.join env ~invite_key:key with
  | Ok () -> Alcotest.fail "a machine that cannot hold keys went on"
  | Error m ->
      Alcotest.(check bool)
        "it says the invite is unspent" true
        (Astring_contains.contains m "invite is unspent"));
  Alcotest.(check bool) "no agent was checked" false (said s "Coding agents");
  Alcotest.(check int) "no phrase was shown" 0 calls.phrases;
  (* No agent works and the member presses Enter: nothing stored, no phrase. *)
  let s, io = scripted [ "" ] in
  let env, calls, _ = setup_env ~works:[] ~net ~code guest io in
  (match Setup.join env ~invite_key:key with
  | Ok () -> Alcotest.fail "setup went on with no working agent"
  | Error _ -> ());
  Alcotest.(check bool)
    "it names how to sign in" true
    (said s "run claude and sign in with /login" && said s "invite is unspent");
  Alcotest.(check int) "no phrase was shown" 0 calls.phrases;
  Alcotest.(check bool)
    "no join is stored" true
    (ok (Join_store.load guest.dir) = None);
  (* Closing the window at the phrase spends nothing either. *)
  let _, io = scripted [ ""; "x" ] in
  let env, calls, _ =
    setup_env ~works:[ claude ] ~found:[ claude ] ~net ~code guest io
  in
  (match Setup.join env ~invite_key:key with
  | Ok () -> Alcotest.fail "setup joined with no phrase pasted back"
  | Error _ -> ());
  Alcotest.(check int) "the phrase was shown" 1 calls.phrases;
  Alcotest.(check bool)
    "no join is stored" true
    (ok (Join_store.load guest.dir) = None)

let setup_typed_path () =
  let _host, _, inv, _relays, net = host_circle () in
  let code = invite_code inv 0 in
  let guest = new_node () in
  (* No agent found; the member types a path the terminal does not know. *)
  let s, io = scripted [ "/nowhere"; "/x/my-agent" ] in
  let env, calls, _ =
    setup_env ~found:[] ~works:[ other ] ~net ~code guest io
  in
  (match Setup.choose_agent env with
  | Ok a -> Alcotest.(check string) "the typed agent" "/x/my-agent" a.path
  | Error e -> Alcotest.fail e);
  Alcotest.(check bool)
    "a path that is no program is asked again" true
    (said s "/nowhere is not a program on this machine");
  Alcotest.(check bool)
    "an agent Digestif cannot limit is said so" true
    (said s Setup.cannot_limit);
  ignore calls;
  (* A known agent never gets that line. *)
  let s, io = scripted [ "" ] in
  let env, _, _ =
    setup_env ~found:[ claude ] ~works:[ claude ] ~net ~code guest io
  in
  ignore (ok (Setup.choose_agent env));
  Alcotest.(check bool)
    "one working agent is confirmed" true
    (said s "Using Claude Code.");
  Alcotest.(check bool)
    "no limit line for a known agent" false
    (said s Setup.cannot_limit)

let setup_resumes_after_a_relay_failure () =
  let _host, _, inv, relays, net = host_circle () in
  let code = invite_code inv 0 in
  let guest = new_node () in
  let s, io = scripted [] in
  let env, _, phrase =
    setup_env ~found:[ claude ] ~works:[ claude ] ~net ~code guest io
  in
  s.answers <- [ ""; "n"; phrase ];
  (* The relays read the dinner, then go down before the join is posted. *)
  let env =
    {
      env with
      post =
        (fun st ->
          List.iter (fun r -> r.Fake_relay.down <- true) relays;
          let r = Invite_node.post ~transport:net guest st in
          List.iter (fun r -> r.Fake_relay.down <- false) relays;
          r);
    }
  in
  (match Setup.join env ~invite_key:(Invite_code.invite_public_key code) with
  | Ok () -> Alcotest.fail "joined with every relay down"
  | Error m ->
      Alcotest.(check bool)
        "the way back is printed" true
        (Astring_contains.contains m "digestif setup to continue"));
  let stored = Option.get (ok (Join_store.load guest.dir)) in
  Alcotest.(check bool) "the join is stored, not posted" false stored.posted;
  (* digestif setup posts the same envelope. *)
  let _, io = scripted [] in
  let env2, calls2, _ =
    setup_env ~found:[ claude ] ~works:[ claude ] ~net ~code guest io
  in
  calls2.agent <- Some claude;
  ok (Setup.resume env2);
  let again = Option.get (ok (Join_store.load guest.dir)) in
  Alcotest.(check bool) "now posted" true again.posted;
  Alcotest.(check string)
    "the same envelope"
    (Envelope.hash stored.join.envelope)
    (Envelope.hash again.join.envelope);
  Alcotest.(check (option string))
    "the circle root is read" (Some inv.dinner_hash) (Node.root guest)

let setup_chat_fails () =
  let _host, _, inv, _relays, net = host_circle () in
  let code = invite_code inv 0 in
  let guest = new_node () in
  let s, io = scripted [] in
  let env, calls, phrase =
    setup_env
      ~chat:(fun a -> if a.name = "Claude Code" then Ok 1 else Ok 0)
      ~net ~code guest io
  in
  s.answers <- [ "1"; "n"; phrase; "2" ];
  ok (Setup.join env ~invite_key:(Invite_code.invite_public_key code));
  Alcotest.(check (list string))
    "another agent is asked for and started" [ "Codex"; "Claude Code" ]
    calls.chats;
  Alcotest.(check bool)
    "the failure is said" true
    (said s "Claude Code stopped with exit 1.")

let setup_words () =
  let p = Phrase.generate () in
  Alcotest.(check (option string))
    "a match" None
    (Setup.mismatch ~expected:p ("  " ^ String.uppercase_ascii p ^ "\n"));
  Alcotest.(check (option string))
    "a missing word" (Some "Word 24 is missing.")
    (Setup.mismatch ~expected:p
       (String.concat " "
          (List.filteri (fun i _ -> i < 23) (String.split_on_char ' ' p))));
  Alcotest.(check (option string))
    "nothing" (Some "Nothing was pasted.")
    (Setup.mismatch ~expected:p "");
  let g = Setup.grid p in
  Alcotest.(check int) "six rows" 6 (List.length g);
  Alcotest.(check bool)
    "numbered down each column" true
    (Astring_contains.contains (List.hd g) "  7 "
    && Astring_contains.contains (List.hd g) " 19 ");
  Alcotest.(check string)
    "the terminal clipboard escape" "\027]52;c;aGk=\007" (Terminal.osc52 "hi");
  Alcotest.(check string) "base64" "YWJj" (Terminal.base64 "abc")

(* The two runs, with a runner that plays the agent: [runs] says whether it runs the command. *)
let agent_runs () =
  let dir = tmpdir () in
  Node.mkdir_p dir;
  let exe = "/home/x/.local/bin/digestif" in
  let play ~answer ~runs : Agents.runner =
   fun argv ->
    let prompt = argv.(Array.length argv - 1) in
    if Astring_contains.contains prompt "setup check" then (
      (if runs then
         let words = String.split_on_char ' ' prompt in
         let rec token = function
           | "check" :: t :: _ -> t
           | _ :: rest -> token rest
           | [] -> ""
         in
         ignore (Agents.write_token dir (token words)));
      Ok { Proc.code = 0; stdout = "Digestif saw the token."; stderr = "" })
    else Ok { Proc.code = 0; stdout = answer; stderr = "" }
  in
  let verdict = function Agents.Works -> "works" | Fails w -> w in
  Alcotest.(check string)
    "answers and runs the command" "works"
    (verdict
       (Agents.check ~run:(play ~answer:"Ready." ~runs:true) ~exe ~dir claude));
  Alcotest.(check bool)
    "an echo of the prompt is no answer" true
    (Astring_contains.contains
       (verdict
          (Agents.check
             ~run:(play ~answer:Agents.answer_prompt ~runs:true)
             ~exe ~dir other))
       "answered something else");
  Alcotest.(check bool)
    "an agent that does not run the command" true
    (Astring_contains.contains
       (verdict
          (Agents.check
             ~run:(play ~answer:"ready" ~runs:false)
             ~exe ~dir claude))
       "did not run digestif setup check");
  let signed_out : Agents.runner =
   fun _ ->
    Ok
      {
        Proc.code = 1;
        stdout = "";
        stderr = "Invalid API key. Please run /login";
      }
  in
  Alcotest.(check bool)
    "a signed-out agent says what it said" true
    (Astring_contains.contains
       (verdict (Agents.check ~run:signed_out ~exe ~dir claude))
       "Please run /login");
  (* Claude Code may run setup check and nothing else; an unknown agent gets only the prompt. *)
  let a = Agents.check_argv claude ~prompt:"p" ~exe ~dir in
  Alcotest.(check bool)
    "Claude Code's permission rule names the command" true
    (Array.mem "Bash(/home/x/.local/bin/digestif setup check:*)" a
    && Array.mem "dontAsk" a);
  Alcotest.(check (array string))
    "an unknown agent: the prompt as its one argument" [| "/x/my-agent"; "p" |]
    (Agents.check_argv other ~prompt:"p" ~exe ~dir);
  Alcotest.(check bool)
    "the answering run has no tools" true
    (Array.mem "--tools=" (Agents.answer_argv claude ~prompt:"p"));
  Alcotest.(check bool)
    "the chat may run setup's subcommands only" true
    (Array.mem "Bash(/home/x/.local/bin/digestif setup:*)"
       (Agents.chat_argv claude ~prompt:"p" ~exe ~dir))

let machine_check () =
  let ok_line = List.hd (Machine_check.run ~macos:true (Keystore.memory ())) in
  Alcotest.(check bool) "a keystore that round-trips" true ok_line.ok;
  let ks = Keystore.memory () in
  let locked =
    {
      ks with
      put =
        (fun _ _ ->
          Error "Keychain write failed (36): User interaction is not allowed.");
    }
  in
  let l = List.hd (Machine_check.run ~ssh:false ~macos:true locked) in
  Alcotest.(check bool)
    "a locked keychain names security unlock-keychain" true
    ((not l.ok) && Astring_contains.contains l.detail "security unlock-keychain");
  let none =
    {
      ks with
      put =
        (fun _ _ ->
          Error
            "Secret Service write failed (1): Cannot autolaunch D-Bus without \
             X11 $DISPLAY");
    }
  in
  let lines =
    Machine_check.run
      ~run:(fun _ -> Ok { Proc.code = 0; stdout = ""; stderr = "" })
      ~macos:false none
  in
  Alcotest.(check bool)
    "no Secret Service names the packages and the unlocked keyring" true
    (let l = List.hd lines in
     (not l.ok)
     && Astring_contains.contains l.detail "libsecret-tools gnome-keyring"
     && Astring_contains.contains l.detail "loginctl enable-linger alone");
  Alcotest.(check (list string))
    "Linux checks systemctl --user too"
    [ "Secret Service"; "systemd" ]
    (List.map (fun (l : Machine_check.line) -> l.label) lines);
  let l =
    List.nth
      (Machine_check.run
         ~run:(fun _ ->
           Ok
             { Proc.code = 1; stdout = ""; stderr = "Failed to connect to bus" })
         ~macos:false (Keystore.memory ()))
      1
  in
  Alcotest.(check bool)
    "systemctl --user failing names loginctl enable-linger" true
    ((not l.ok) && Astring_contains.contains l.detail "loginctl enable-linger")

let () =
  Alcotest.run "digestif-invite-flow"
    [
      ( "invite",
        [
          Alcotest.test_case "host, guest, watcher, revoke" `Quick flow;
          Alcotest.test_case "codes no open invite names" `Quick refused;
          Alcotest.test_case "ask store" `Quick asks_store;
          Alcotest.test_case "url handler" `Quick url_handler;
        ] );
      ( "setup",
        [
          Alcotest.test_case "the join, then a re-run" `Quick setup_joins;
          Alcotest.test_case "stops with nothing spent" `Quick
            setup_stops_unspent;
          Alcotest.test_case "a typed path" `Quick setup_typed_path;
          Alcotest.test_case "resumes after a relay failure" `Quick
            setup_resumes_after_a_relay_failure;
          Alcotest.test_case "a failed chat asks for another agent" `Quick
            setup_chat_fails;
          Alcotest.test_case "the phrase's words" `Quick setup_words;
          Alcotest.test_case "an agent's two runs" `Quick agent_runs;
          Alcotest.test_case "what the machine needs" `Quick machine_check;
        ] );
    ]
