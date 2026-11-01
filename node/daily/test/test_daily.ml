(* The node's daily acts against two in-process relays, one of them mailing: the mail key's
   admission and counter, the digest from an ask in the node's ask store to mail request, answer
   links settling an ask, lapses, a join ask's answer revoking through the invite flow, and pairing
   a phone. *)

open Digestif_core
open Digestif_mail
open Digestif_daily

let ok = function Ok v -> v | Error e -> Alcotest.fail e

let tmpdir () =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "digestif-daily-%d-%s" (Unix.getpid ())
       (B64url.encode (Crypto.random 6)))

let in_hours h = Time_fmt.of_unix (Unix.gettimeofday () +. (h *. 3600.))
let mailing = "https://a.test"

type member = {
  node : Node.t;
  keystore : Keystore.t;
  dir : string;
  phrase : string;
  identity : string;
}

type circle = {
  relays : Fake_relay.t list;
  net : Relay_client.transport;
  host : member;
  roman : member;
  mailer_priv : string;
}

let member () =
  let keystore = Keystore.memory () and dir = tmpdir () in
  let node = Node.open_ ~keystore dir in
  let phrase = Phrase.generate () in
  let d = ok (Node.init node ~phrase) in
  ok (Mail_key.prepare node ~identity:d.identity);
  { node; keystore; dir; phrase; identity = Keys.public d.identity }

let card (m : member) name agent_name =
  let enc = ok (Node.encryption_key m.node) in
  ignore
    (ok
       (Node.write m.node ~kind:"card"
          (Bodies.make_card ~name ~agent_name
             ~encryption_key:(Keys.encryption_public enc))))

let make_circle () =
  let host = member () and roman = member () in
  let invite = Crypto.generate_signing_key () in
  let dinner =
    Bodies.dinner_json
      {
        host = host.identity;
        date = "2026-10-27";
        label = "AI Dinner 2";
        guests =
          [
            {
              name = "Roman";
              invite_key = Keys.public invite;
              expires_at = in_hours 72.;
            };
          ];
        relays = [ mailing; "https://b.test" ];
      }
  in
  let root, _ = ok (Node.write host.node ~kind:"dinner" dinner) in
  let mailer_priv = Mail_crypto.X25519.generate () in
  ignore
    (ok
       (Node.write host.node ~kind:"relay"
          (Bodies.make_relay ~url:mailing ~mailer:true
             ~encryption_key:
               (Keys.encode_x25519 (Mail_crypto.X25519.public mailer_priv))
             ())));
  card host "Mike" "Otto";
  List.iter (fun m -> Node.set_root m.node root) [ host; roman ];
  let relays =
    [
      Fake_relay.create ~url:mailing ~root;
      Fake_relay.create ~url:"https://b.test" ~root;
    ]
  in
  (List.hd relays).mailer <- true;
  let net = Fake_relay.network relays in
  List.iter
    (fun (r : Fake_relay.t) ->
      Log.add_relay host.node.log r.url;
      Log.add_relay roman.node.log r.url)
    relays;
  ignore (ok (Sync.sync ~transport:net host.node));
  let rd = ok (Phrase.derive roman.phrase) in
  let join =
    Bodies.make_join ~invite_key:invite ~dinner_hash:root ~identity:rd.identity
      ~device:(ok (Node.device_key roman.node))
  in
  let sg = Envelope.create ~key:invite ~seq:1 ~epoch:0 ~kind:"join" join in
  List.iter
    (fun (r : Fake_relay.t) ->
      ignore
        (ok
           (Result.map_error Relay_client.error_to_string
              (Relay_client.append net ~base:r.url ~key:None sg))))
    relays;
  ignore (ok (Node.import roman.node sg));
  ignore (ok (Sync.sync ~transport:net roman.node));
  card roman "Roman" "Ada";
  ignore (ok (Sync.sync ~transport:net roman.node));
  ignore (ok (Sync.sync ~transport:net host.node));
  { relays; net; host; roman; mailer_priv }

let relay c url = List.find (fun (r : Fake_relay.t) -> r.url = url) c.relays
let run ?now c (m : member) = ok (Daily.run ~transport:c.net ?now m.node)
let mail_pub (m : member) = Option.get (Log.get_config m.node.log Node.k_mail)

let mail_key_admission () =
  let c = make_circle () in
  let dinner = List.hd (Log.of_kind c.host.node.log "dinner") in
  Alcotest.(check int)
    "the dinner keeps seq 1 of the host's chain" 1 dinner.signed.envelope.seq;
  Alcotest.(check bool)
    "not admitted before the first pass" true
    (Fold.find (Node.fold c.host.node) (mail_pub c.host) = None);
  List.iter
    (fun (m : member) ->
      let _, p = run c m in
      (match p.mail_key with
      | Mail_key.Appended _ -> ()
      | _ -> Alcotest.fail "the first pass appends the mail key's device body");
      let k =
        Option.get (Fold.find (Fake_relay.fold (relay c mailing)) (mail_pub m))
      in
      Alcotest.(check string)
        "a mail key on the relay" "mail"
        (Bodies.role_to_string k.role);
      Alcotest.(check string)
        "under the member's identity" m.identity k.identity;
      let _, p = run c m in
      Alcotest.(check bool) "once" true (p.mail_key = Mail_key.Admitted))
    [ c.host; c.roman ];
  (* A node set up without the phrase-signed body says so rather than guessing. *)
  let bare = Node.open_ ~keystore:(Keystore.memory ()) (tmpdir ()) in
  ignore (ok (Node.init bare ~phrase:(Phrase.generate ())));
  Node.set_root bare (Option.get (Node.root c.host.node));
  Alcotest.(check bool)
    "waits for its own admission" true
    (ok (Mail_key.admit bare (Node.fold bare)) = Mail_key.Waiting)

let mail_seq_counter () =
  let m = member () in
  let next = Mail_key.next_seq m.node in
  Alcotest.(check (list int))
    "counts from 1" [ 1; 2; 3 ]
    (List.init 3 (fun _ -> next ()));
  Node.close m.node;
  let again = Node.open_ ~keystore:m.keystore m.dir in
  Alcotest.(check int) "survives a restart" 4 (Mail_key.next_seq again ())

let ask ?(lapses_at = in_hours 72.) title : Ask.t =
  {
    title;
    detail = "Phong's agent asked for an intro about eval harnesses.";
    about = None;
    options =
      [
        { id = "yes"; label = "Make the intro"; recommended = true };
        { id = "no"; label = "Decline"; recommended = false };
      ];
    on_no_answer = "no";
    lapses_at;
  }

let queue c a = ignore (ok (Asks_mail.add c.host.node.log a))

let ready c =
  ignore (run c c.host);
  ignore (run c c.roman);
  Log.set_config c.host.node.log Daily_digest.k_email "mike@example.com";
  Log.set_config c.host.node.log Daily_digest.k_hour "0"

let digest_body c hash =
  let s =
    List.find
      (fun (s : Fake_relay.stored) -> s.hash = hash)
      (relay c mailing).items
  in
  Option.get s.signed.body

let query_param url name =
  match String.split_on_char '?' url with
  | [ _; q ] ->
      List.find_map
        (fun kv ->
          match String.split_on_char '=' kv with
          | [ k; v ] when k = name -> Some v
          | _ -> None)
        (String.split_on_char '&' q)
  | _ -> None

(* What the mailing relay does when the member confirms a link: open the sealed answer with the
   URL's secret, check the decision, append it. *)
let confirm c ~digest url =
  let id =
    List.nth
      (String.split_on_char '/' (List.hd (String.split_on_char '?' url)))
      5
  in
  let secret = ok (B64url.decode (Option.get (query_param url "s"))) in
  let links = ok (Seal.member "links" (digest_body c digest)) in
  let record =
    match links with
    | `List l -> List.find (fun r -> Seal.string_member "id" r = Ok id) l
    | _ -> Alcotest.fail "links"
  in
  let sealed_answer = ok (Seal.b64_member "sealed_answer" record) in
  let ask = ok (Seal.string_member "ask" record) in
  let payload =
    ok (Link.open_answer ~id:(ok (B64url.decode id)) ~secret sealed_answer)
  in
  let fold = Fake_relay.fold (relay c mailing) in
  let mail_keys =
    Hashtbl.fold
      (fun _ (k : Fold.key_state) acc ->
        if k.role = Mail && k.identity = c.host.identity then k.key :: acc
        else acc)
      fold.keys []
  in
  let signed = ok (Link.check_answer ~mail_keys ~ask payload) in
  ignore (Fake_relay.force (relay c mailing) signed);
  ask

let email_of c digest =
  let request = List.assoc digest (relay c mailing).mailed in
  ok
    (Digest.render ~mailer_priv:c.mailer_priv ~relay:mailing
       ~digest_body:(digest_body c digest) ~request)

let option_urls email =
  match ok (Seal.member "asks" email) with
  | `List [ a ] -> (
      match ok (Seal.member "options" a) with
      | `List l -> List.map (fun o -> ok (Seal.string_member "link" o)) l
      | _ -> Alcotest.fail "options")
  | _ -> Alcotest.fail "one ask in the email"

let digest_end_to_end () =
  let c = make_circle () in
  ready c;
  ignore
    (ok
       (Node.write c.roman.node ~kind:"summary"
          (`Assoc [ ("text", `String "shipped the D1 fold.") ])));
  ignore (ok (Sync.sync ~transport:c.net c.roman.node));
  queue c (ask "Introduce Phong to Andrey?");
  let _, p = run c c.host in
  let w = Option.get (ok p.digest) in
  Alcotest.(check int) "the ask went in" 1 (List.length w.asks);
  Alcotest.(check int)
    "no ask is left for the next digest" 0
    (List.length (Asks.unappended c.host.node.log));
  Alcotest.(check (list (option string)))
    "the ask keeps the envelope it went in as"
    [ Some (List.hd w.asks) ]
    (List.map (fun (a : Asks.t) -> a.envelope) (Asks.list c.host.node.log));
  List.iter
    (fun (r : Fake_relay.t) ->
      Alcotest.(check bool)
        ("the digest is on " ^ r.url)
        true
        (List.exists (fun (s : Fake_relay.stored) -> s.hash = w.digest) r.items))
    c.relays;
  Alcotest.(check bool)
    "mailed" true
    (match p.sent with
    | [ { result = Ok Relay_client.Sent; _ } ] -> true
    | _ -> false);
  Alcotest.(check int)
    "the secrets are dropped once sent" 0
    (List.length (Store.mail_requests c.host.node.log));
  let email = email_of c w.digest in
  Alcotest.(check (result string string))
    "subject"
    (Ok
       (Daily_digest.subject ~now:(Unix.gettimeofday ()) ~came_in:1 ~went_out:0
          ~asks:1))
    (Seal.string_member "subject" email);
  Alcotest.(check bool)
    "came in" true
    (Astring_contains.contains
       (Yojson.Safe.to_string email)
       "Roman (Ada): shipped the D1 fold.");
  (match
     ok
       (Result.map_error Relay_client.error_to_string
          (Relay_client.mail c.net ~base:mailing
             ~key:(ok (Node.device_key c.host.node))
             (List.assoc w.digest (relay c mailing).mailed)))
   with
  | Already_sent -> ()
  | Sent -> Alcotest.fail "a repeat mails nothing");
  let _, p = run c c.host in
  Alcotest.(check bool) "one digest a day" true (ok p.digest = None);
  (* The member confirms "Make the intro" from the email; the node reads it, and then the laptop's
     own later answer, before either is settled. *)
  let ask_hash = confirm c ~digest:w.digest (List.hd (option_urls email)) in
  ignore (ok (Sync.sync ~transport:c.net c.host.node));
  let enc = ok (Node.encryption_key c.host.node) in
  ignore
    (ok
       (Node.write c.host.node ~kind:"decision"
          (Ask.decision_body ~member_key:enc.public ~ask:ask_hash ~option:"no")));
  let _, p = run c c.host in
  (match p.settled with
  | [
   {
     hash = Some hash;
     outcome = Some { option = "yes"; source = Decided; _ };
     _;
   };
  ] ->
      Alcotest.(check string) "the ask" ask_hash hash
  | _ -> Alcotest.fail "the first answer read settles the ask");
  let _, p = run c c.host in
  Alcotest.(check int) "settled once" 0 (List.length p.settled);
  match ok (Decisions.read c.host.node (Node.fold c.host.node)) with
  | [ a ] ->
      Alcotest.(check (list string))
        "the later one is shown beside it" [ "yes"; "no" ]
        (List.map snd a.decisions);
      Alcotest.(check string)
        "the first stands" "yes" (Option.get a.outcome).option
  | _ -> Alcotest.fail "one ask"

let mail_waits_for_the_relay () =
  let c = make_circle () in
  ready c;
  queue c (ask "Lunch?");
  (relay c mailing).down <- true;
  let _, p = run c c.host in
  let w = Option.get (ok p.digest) in
  Alcotest.(check int)
    "nothing sent while the mailing relay is down" 0 (List.length p.sent);
  Alcotest.(check int)
    "the request is kept" 1
    (List.length (Store.mail_requests c.host.node.log));
  (relay c mailing).down <- false;
  let _, p = run c c.host in
  Alcotest.(check (list string))
    "sent once the digest is there" [ w.digest ]
    (List.filter_map
       (fun (s : Daily_digest.sent) ->
         if s.result = Ok Sent then Some s.digest else None)
       p.sent);
  Alcotest.(check int)
    "then dropped" 0
    (List.length (Store.mail_requests c.host.node.log))

let updates_section () =
  let c = make_circle () in
  let path = Digestif_update.Schedule.report_path c.host.dir in
  let lines =
    [
      "Updated Digestif to 0.2.0.";
      "Release 0.3.0 was not installed: not signed by Roman.";
    ]
  in
  Digestif_update.Report.save path
    (Digestif_update.Report.record Digestif_update.Report.empty ~now:1. lines);
  (* A digest that cannot be written takes nothing from the report. *)
  (match Daily_digest.write c.host.node ~now:(Unix.gettimeofday ()) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "a digest with no email to go to");
  Alcotest.(check (list string))
    "kept while no digest is written" lines
    (Digestif_update.Report.load path).pending;
  ready c;
  let _, p = run c c.host in
  let w = Option.get (ok p.digest) in
  let email = Yojson.Safe.to_string (email_of c w.digest) in
  List.iter
    (fun l ->
      Alcotest.(check bool)
        ("the digest says " ^ l) true
        (Astring_contains.contains email l))
    ("Updates" :: lines);
  Alcotest.(check (list string))
    "taken once the digest is appended" []
    (Digestif_update.Report.load path).pending

(* Quiet hours: a span of local time, past midnight when the start is later than the end. *)
let quiet_hours () =
  let at h m =
    let g = Unix.localtime (Unix.gettimeofday ()) in
    fst (Unix.mktime { g with tm_hour = h; tm_min = m; tm_sec = 0 })
  in
  let span start stop =
    ok (Result.map_error (fun _ -> "bad span") (Quiet_hours.make ~start ~stop))
  in
  let night = span "22:00" "07:00" in
  Alcotest.(check bool)
    "late evening" true
    (Quiet_hours.active night ~now:(at 23 30));
  Alcotest.(check bool)
    "early morning" true
    (Quiet_hours.active night ~now:(at 6 59));
  Alcotest.(check bool)
    "the end is outside" false
    (Quiet_hours.active night ~now:(at 7 0));
  Alcotest.(check bool) "midday" false (Quiet_hours.active night ~now:(at 12 0));
  let lunch = span "12:00" "13:00" in
  Alcotest.(check bool)
    "a daytime span" true
    (Quiet_hours.active lunch ~now:(at 12 30));
  Alcotest.(check (float 0.5))
    "ends today" (at 13 0)
    (Quiet_hours.ends_at lunch ~now:(at 12 30));
  Alcotest.(check bool)
    "ends tomorrow morning" true
    (let e = Quiet_hours.ends_at night ~now:(at 23 30) in
     e > at 23 30 && (Unix.localtime e).tm_hour = 7);
  Alcotest.(check bool)
    "start = end refused" true
    (Quiet_hours.make ~start:"07:00" ~stop:"07:00" = Error `Empty);
  Alcotest.(check bool)
    "a bad time refused" true
    (Quiet_hours.make ~start:"25:00" ~stop:"07:00" = Error `Start);
  Alcotest.(check bool)
    "round trip" true
    (Quiet_hours.of_string (Quiet_hours.to_string night) = Some night)

(* The digest, which carries every ask, waits out the member's quiet hours. *)
let digest_waits_for_quiet_hours () =
  let c = make_circle () in
  ready c;
  let log = c.host.node.log in
  let now = Unix.gettimeofday () in
  let g = Unix.localtime now in
  let m = (g.tm_hour * 60) + g.tm_min in
  let hhmm m =
    let m = (m + 1440) mod 1440 in
    Printf.sprintf "%02d:%02d" (m / 60) (m mod 60)
  in
  Quiet_hours.set log
    (Result.get_ok
       (Quiet_hours.make ~start:(hhmm (m - 60)) ~stop:(hhmm (m + 60))));
  Alcotest.(check bool)
    "not due inside quiet hours" false
    (Daily_digest.due c.host.node ~now);
  let _, p = run c c.host in
  Alcotest.(check bool) "no digest written" true (ok p.digest = None);
  Quiet_hours.clear log;
  Alcotest.(check bool)
    "due once they are cleared" true
    (Daily_digest.due c.host.node ~now)

(* The silence report comes from the web layer through a hook and lands as a section. *)
let silence_section () =
  let c = make_circle () in
  ready c;
  let asked = ref None in
  let silence _node ~since ~now:_ =
    asked := Some since;
    Some { Digest.title = "Silence"; lines = [ "Ada: the harness timed out." ] }
  in
  let _, p = ok (Daily.run ~transport:c.net ~silence c.host.node) in
  let w = Option.get (ok p.digest) in
  let email = Yojson.Safe.to_string (email_of c w.digest) in
  Alcotest.(check bool) "asked with no digest before" true (!asked = Some None);
  List.iter
    (fun l ->
      Alcotest.(check bool)
        ("the digest says " ^ l) true
        (Astring_contains.contains email l))
    [ "Silence"; "Ada: the harness timed out." ]

let lapse () =
  let c = make_circle () in
  ready c;
  queue c (ask ~lapses_at:(in_hours 1.) "Coffee?");
  let _, p = run c c.host in
  let w = Option.get (ok p.digest) in
  let ask_hash = List.hd w.asks in
  (* An answer from another identity is not the member's. *)
  let host_key = (ok (Node.encryption_key c.host.node)).public in
  ignore
    (ok
       (Node.write c.roman.node ~kind:"decision"
          (Ask.decision_body ~member_key:host_key ~ask:ask_hash ~option:"yes")));
  ignore (ok (Sync.sync ~transport:c.net c.roman.node));
  let _, p = run c c.host in
  Alcotest.(check int) "open until it lapses" 0 (List.length p.settled);
  let later = Unix.gettimeofday () +. 7200. in
  match
    ok (Decisions.settle c.host.node (Node.fold c.host.node) ~now:later)
  with
  | [
   { outcome = Some { option = "no"; source = Lapsed; decision = None; _ }; _ };
  ] ->
      ()
  | _ -> Alcotest.fail "an unanswered ask settles on its on_no_answer"

(* Roman's join on the host's dinner, as the invite join watcher raises it: an ask keyed
   join:<invite key> in the node's ask store, beside the ledger record it answers. *)
let join_ask ?lapses_at c =
  let module H = Digestif_invite.Host_watch in
  let now = Option.get (Ptime.of_float_s (Unix.gettimeofday ())) in
  let r : H.record =
    {
      dinner_hash = Option.get (Node.root c.host.node);
      guest_name = "Roman";
      guest_email = "roman@example.com";
      invite_key = "ed25519:invite";
      expires_at = now;
      state = Joined { identity_key = c.roman.identity; confirmed = false };
    }
  in
  ok (H.save c.host.node.dir [ r ]);
  let a =
    H.to_store
      (H.ask_for ~now ~joined_at:now r ~identity_key:c.roman.identity
         ~why:"Someone joined.")
  in
  let a =
    match lapses_at with Some l -> { a with lapses_at = l } | None -> a
  in
  ok (Asks.raise_ c.host.node.log a);
  a.key

let revoked c identity =
  match Fold.find (Fake_relay.fold (relay c mailing)) identity with
  | Some k -> k.revoked_by <> None
  | None -> false

let join_answer_revokes () =
  let c = make_circle () in
  ready c;
  let key = join_ask c in
  let _, p = run c c.host in
  let w = Option.get (ok p.digest) in
  Alcotest.(check int) "the join ask went in" 1 (List.length w.asks);
  (* The host answers revoke from the email: the second option. *)
  let urls = option_urls (email_of c w.digest) in
  ignore (confirm c ~digest:w.digest (List.nth urls 1));
  let _, p = run c c.host in
  (match p.settled with
  | [
   {
     key = k;
     outcome = Some { option = "revoke"; source = Decided; _ };
     revoke = Some _;
     _;
   };
  ] ->
      Alcotest.(check string) "the join ask" key k
  | _ -> Alcotest.fail "the decision settles the join ask with a revoke");
  Alcotest.(check bool)
    "the revoke reached the relay" true
    (revoked c c.roman.identity);
  match ok (Digestif_invite.Host_watch.load c.host.node.dir) with
  | [ { state = Revoked { identity_key }; _ } ] ->
      Alcotest.(check string) "the ledger" c.roman.identity identity_key
  | _ -> Alcotest.fail "the ledger records the revoke"

let join_lapse_past_window () =
  let c = make_circle () in
  ready c;
  let key = join_ask ~lapses_at:(in_hours 1.) c in
  let later = Unix.gettimeofday () +. (8. *. 86400.) in
  Alcotest.(check int)
    "past the device's window a lapse waits for the phrase" 0
    (List.length
       (ok (Decisions.settle c.host.node (Node.fold c.host.node) ~now:later)));
  Alcotest.(check bool)
    "the ask stays open" true
    ((Option.get (Asks.find c.host.node.log key)).answer = None);
  let soon = Unix.gettimeofday () +. 7200. in
  match ok (Decisions.settle c.host.node (Node.fold c.host.node) ~now:soon) with
  | [
   {
     outcome = Some { option = "revoke"; source = Lapsed; _ };
     revoke = Some _;
     _;
   };
  ] ->
      ()
  | _ -> Alcotest.fail "inside the window the lapse revokes with the device key"

(* A join ask that lapses with no decision inside the device key's window: the run loop's pass
   signs the revoke with the device key that wrote the dinner, saves the ledger, and its second
   sync appends the revoke to every relay. *)
let join_lapse_revokes_everywhere () =
  let c = make_circle () in
  ready c;
  let key = join_ask ~lapses_at:(in_hours (-1.)) c in
  let _, p = run c c.host in
  (match p.settled with
  | [
   {
     key = k;
     outcome = Some { option = "revoke"; source = Lapsed; _ };
     revoke = Some _;
     _;
   };
  ] ->
      Alcotest.(check string) "the join ask" key k
  | _ -> Alcotest.fail "the lapse settles the join ask with a revoke");
  Alcotest.(check int)
    "nothing waits on the phrase" 0
    (List.length p.needs_phrase);
  List.iter
    (fun (r : Fake_relay.t) ->
      match Fold.find (Fake_relay.fold r) c.roman.identity with
      | Some k ->
          Alcotest.(check bool)
            (r.url ^ " revoked the identity")
            true (k.revoked_by <> None)
      | None -> Alcotest.failf "%s does not know the identity" r.url)
    c.relays;
  (match ok (Digestif_invite.Host_watch.load c.host.node.dir) with
  | [ { state = Revoked { identity_key }; _ } ] ->
      Alcotest.(check string) "the ledger" c.roman.identity identity_key
  | _ -> Alcotest.fail "the ledger records the revoke");
  match (Option.get (Asks.find c.host.node.log key)).answered_via with
  | Some Lapse -> ()
  | _ -> Alcotest.fail "the ask records that it lapsed"

let sections_of email =
  match ok (Seal.member "sections" email) with
  | `List l -> List.map (fun s -> ok (Seal.string_member "title" s)) l
  | _ -> Alcotest.fail "sections"

(* One the node first acts on past the window stays open and lapsed, revokes nothing, and leads
   every digest until the person answers it with the phrase. *)
let join_lapse_leads_digest () =
  let c = make_circle () in
  ready c;
  ignore
    (ok
       (Node.write c.roman.node ~kind:"summary"
          (`Assoc [ ("text", `String "shipped the D1 fold.") ])));
  ignore (ok (Sync.sync ~transport:c.net c.roman.node));
  let key = join_ask ~lapses_at:(in_hours 1.) c in
  let day = 86400. and now = Unix.gettimeofday () in
  let _, p = run ~now:(now +. (8. *. day)) c c.host in
  Alcotest.(check int) "nothing settles" 0 (List.length p.settled);
  (match p.needs_phrase with
  | [ a ] -> Alcotest.(check string) "the join ask waits" key a.key
  | _ -> Alcotest.fail "the lapsed join ask waits on the phrase");
  Alcotest.(check bool)
    "the ask stays open" true
    ((Option.get (Asks.find c.host.node.log key)).answer = None);
  Alcotest.(check bool)
    "nothing is revoked" false
    (List.exists
       (fun (r : Fake_relay.t) ->
         match Fold.find (Fake_relay.fold r) c.roman.identity with
         | Some k -> k.revoked_by <> None
         | None -> false)
       c.relays);
  let leads (w : Daily_digest.written) =
    let email = email_of c w.digest in
    match sections_of email with
    | "Waiting on your recovery phrase" :: _ ->
        Alcotest.(check bool)
          "it names the command" true
          (Astring_contains.contains
             (Yojson.Safe.to_string email)
             ("digestif asks answer " ^ key ^ " revoke"))
    | titles ->
        Alcotest.failf "the digest leads with %s" (String.concat ", " titles)
  in
  leads (Option.get (ok p.digest));
  let _, p = run ~now:(now +. (9. *. day)) c c.host in
  let w = Option.get (ok p.digest) in
  Alcotest.(check int) "the ask is not appended twice" 0 (List.length w.asks);
  leads w

let phone_pairing () =
  let c = make_circle () in
  let phone = Crypto.generate_signing_key () in
  let phone_x_priv = Mail_crypto.X25519.generate () in
  let code =
    Phone.pairing_code ~ed25519:phone.pub
      ~x25519:(Mail_crypto.X25519.public phone_x_priv)
  in
  (match Phones.add c.host.node ~phrase:c.roman.phrase ~code with
  | Error (Phones.Recovery_phrase _) -> ()
  | _ -> Alcotest.fail "another member's phrase is refused, naming the phrase");
  (match Phones.add c.host.node ~phrase:c.host.phrase ~code:(code ^ "x") with
  | Error (Phones.Pairing_code _) -> ()
  | _ -> Alcotest.fail "a code whose check does not match names the code");
  let _, key =
    ok
      (Result.map_error Phones.error_message
         (Phones.add c.host.node ~phrase:c.host.phrase ~code))
  in
  ignore (ok (Sync.sync ~transport:c.net c.host.node));
  let k = Option.get (Fold.find (Fake_relay.fold (relay c mailing)) key) in
  Alcotest.(check string) "a device of the member" c.host.identity k.identity;
  Alcotest.(check string) "role" "device" (Bodies.role_to_string k.role);
  let row =
    List.find
      (fun (r : Log.row) ->
        match r.signed.body with
        | Some b ->
            Bodies.parse_device b
            |> Result.map (fun (d : Bodies.device) -> d.key = key)
            = Ok true
        | None -> false)
      (Log.of_kind c.host.node.log "device")
  in
  let secret, identity, relays =
    ok
      (Phone.open_enrollment ~phone_x25519_priv:phone_x_priv
         (Option.get row.signed.body))
  in
  Alcotest.(check string)
    "the member's encryption key" (ok (Node.encryption_key c.host.node)).secret
    secret;
  Alcotest.(check string) "identity" c.host.identity identity;
  Alcotest.(check (list string)) "relays" [ mailing; "https://b.test" ] relays

(* A release-key revocation posted on the circle (docs/protocol.md, release_revocation) reaches a
   running node's update state through its daily pass, with no release channel involved. *)
module U = Digestif_update

let release_secret n =
  Crypto.signing_key_of_seed_exn (String.make 32 (Char.chr n))

let signer_a = release_secret 1
let signer_b = release_secret 2
let outsider = release_secret 5

let release_revocation ~by target =
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
  let doc = ok (U.Release.revocation_of_string bytes) in
  let signatures =
    List.fold_left
      (fun sigs secret ->
        U.Release.add_signature ~domain:U.Release.revocation_domain ~secret
          bytes sigs)
      [] by
  in
  U.Circle_revocation.to_body { bytes; doc; signatures }

(* The member's node trusts the two test signers rather than the shipped set. *)
let trust_test_signers (m : member) =
  U.State.save
    (U.Schedule.state_path m.dir)
    {
      (U.State.initial ()) with
      trust =
        {
          signers =
            [
              { name = "A"; key = Keys.public signer_a };
              { name = "B"; key = Keys.public signer_b };
            ];
          revoked = [];
        };
    }

let revoked_in (m : member) =
  (ok (U.State.load (U.Schedule.state_path m.dir))).trust.revoked

let circle_revocation_halts_a_running_node () =
  let c = make_circle () in
  trust_test_signers c.host;
  ignore
    (ok
       (Node.write c.roman.node ~kind:"release_revocation"
          (release_revocation ~by:[ signer_a ] signer_b)));
  ignore (ok (Sync.sync ~transport:c.net c.roman.node));
  let _, p = run c c.host in
  Alcotest.(check (list string))
    "the pass reports the newly revoked key"
    [ Keys.public signer_b ]
    (ok p.release_revocations);
  Alcotest.(check (list string))
    "and the update state keeps it"
    [ Keys.public signer_b ]
    (revoked_in c.host);
  let _, again = run c c.host in
  Alcotest.(check (list string))
    "a later pass revokes nothing new" []
    (ok again.release_revocations);
  Alcotest.(check (list string))
    "and the state is unchanged"
    [ Keys.public signer_b ]
    (revoked_in c.host)

let circle_revocation_by_an_outsider_is_a_fault () =
  let c = make_circle () in
  trust_test_signers c.host;
  let hash, _ =
    ok
      (Node.write c.roman.node ~kind:"release_revocation"
         (release_revocation ~by:[ outsider ] signer_b))
  in
  ignore (ok (Sync.sync ~transport:c.net c.roman.node));
  let _, p = run c c.host in
  Alcotest.(check (list string))
    "nothing is revoked" [] (ok p.release_revocations);
  Alcotest.(check (list string)) "state untouched" [] (revoked_in c.host);
  Alcotest.(check bool)
    "the member is shown a fault naming the message" true
    (List.exists
       (fun (f : Log.fault) ->
         f.kind = "release_revocation"
         && String.length f.detail >= String.length hash
         && String.sub f.detail 0 (String.length hash) = hash)
       (Log.open_faults c.host.node.log))

let circle_revocation_needs_both_fields () =
  let c = make_circle () in
  trust_test_signers c.host;
  let hash, _ =
    ok
      (Node.write c.roman.node ~kind:"release_revocation"
         (`Assoc [ ("document", `String "x") ]))
  in
  ignore (ok (Sync.sync ~transport:c.net c.roman.node));
  let _, p = run c c.host in
  Alcotest.(check (list string))
    "nothing is revoked" [] (ok p.release_revocations);
  Alcotest.(check bool)
    "the fold rejects it" true
    (List.mem_assoc hash (Node.fold c.host.node).rejected)

(* A recall posted on the circle (docs/protocol.md, release_recall) reaches a running node's next
   update pass through its daily pass, with no release channel involved. *)
let circle_recall_reaches_the_update_pass () =
  let c = make_circle () in
  let bytes =
    U.Release.recall_to_string
      {
        recalled_version = ok (U.Version.of_string "0.1.7");
        reason = "it loses mail";
        recalled_at = "2026-11-01T00:00:00.000Z";
      }
  in
  let doc = ok (U.Release.recall_of_string bytes) in
  let signatures =
    U.Release.add_signature ~domain:U.Release.recall_domain ~secret:signer_a
      bytes []
  in
  ignore
    (ok
       (Node.write c.roman.node ~kind:"release_recall"
          (U.Circle_recall.to_body { bytes; doc; signatures })));
  ignore (ok (Sync.sync ~transport:c.net c.roman.node));
  let _, p = run c c.host in
  match p.release_recalls with
  | [ r ] ->
      Alcotest.(check string) "the document's exact bytes" bytes r.bytes;
      Alcotest.(check int) "its signature" 1 (List.length r.signatures)
  | l -> Alcotest.failf "expected one recall, got %d" (List.length l)

let () =
  Alcotest.run "digestif-daily"
    [
      ( "release revocation",
        [
          Alcotest.test_case "halts a running node" `Quick
            circle_revocation_halts_a_running_node;
          Alcotest.test_case "an outsider's is a fault" `Quick
            circle_revocation_by_an_outsider_is_a_fault;
          Alcotest.test_case "needs both fields" `Quick
            circle_revocation_needs_both_fields;
          Alcotest.test_case "a recall reaches the update pass" `Quick
            circle_recall_reaches_the_update_pass;
        ] );
      ( "mail key",
        [
          Alcotest.test_case "admitted once the device is" `Quick
            mail_key_admission;
          Alcotest.test_case "sequence counter" `Quick mail_seq_counter;
        ] );
      ( "digest",
        [
          Alcotest.test_case "end to end" `Quick digest_end_to_end;
          Alcotest.test_case "mail waits for the relay" `Quick
            mail_waits_for_the_relay;
          Alcotest.test_case "updates section" `Quick updates_section;
          Alcotest.test_case "lapse" `Quick lapse;
          Alcotest.test_case "quiet hours" `Quick quiet_hours;
          Alcotest.test_case "waits for quiet hours" `Quick
            digest_waits_for_quiet_hours;
          Alcotest.test_case "silence section" `Quick silence_section;
        ] );
      ( "join ask",
        [
          Alcotest.test_case "a decision revokes" `Quick join_answer_revokes;
          Alcotest.test_case "a lapse past the window waits" `Quick
            join_lapse_past_window;
          Alcotest.test_case "a lapse revokes on every relay" `Quick
            join_lapse_revokes_everywhere;
          Alcotest.test_case "a lapse past the window leads the digest" `Quick
            join_lapse_leads_digest;
        ] );
      ("phone", [ Alcotest.test_case "pairing" `Quick phone_pairing ]);
    ]
