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
    ]
