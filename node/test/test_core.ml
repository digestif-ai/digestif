open Digestif_core

let check_str = Alcotest.(check string)
let ok = function Ok v -> v | Error e -> Alcotest.fail e
let unhex s = ok (Hex.decode s)

(* JCS, RFC 8785 *)

let jcs_numbers () =
  List.iter
    (fun (f, want) -> check_str (Printf.sprintf "%h" f) want (Jcs.number f))
    [
      (0.0, "0");
      (-0.0, "0");
      (1.0, "1");
      (-1.5, "-1.5");
      (1e21, "1e+21");
      (1e20, "100000000000000000000");
      (1e-7, "1e-7");
      (0.000001, "0.000001");
      (333333333.33333329, "333333333.3333333");
      (1e30, "1e+30");
      (4.50, "4.5");
      (2e-3, "0.002");
      (1e-27, "1e-27");
      (5e-324, "5e-324");
      (1.7976931348623157e308, "1.7976931348623157e+308");
      (295147905179352830000.0, "295147905179352830000");
      (9007199254740992.0, "9007199254740992");
      (123456789012345680000.0, "123456789012345680000");
    ]

let jcs_rfc_example () =
  let input =
    {|{"numbers":[333333333.33333329,1E30,4.50,2e-3,0.000000000000000000000000001],"string":"\u20ac$\u000F\u000aA'\u0042\u0022\u005c\\\"\/","literals":[null,true,false]}|}
  in
  check_str "RFC 8785 section 3.2.4"
    {|{"literals":[null,true,false],"numbers":[333333333.3333333,1e+30,4.5,0.002,1e-27],"string":"€$\u000f\nA'B\"\\\\\"/"}|}
    (Jcs.encode (Yojson.Safe.from_string input))

let jcs_sorting () =
  let input =
    {|{"\u20ac":"Euro Sign","\r":"Carriage Return","\ufb33":"Hebrew Letter Dalet With Dagesh","1":"One","\ud83d\ude00":"Emoji: Grinning Face","\u0080":"Control","\u00f6":"Latin Small Letter O With Diaeresis"}|}
  in
  let names =
    match
      Yojson.Safe.from_string (Jcs.encode (Yojson.Safe.from_string input))
    with
    | `Assoc f -> List.map snd f
    | _ -> []
  in
  Alcotest.(check (list string))
    "UTF-16 order"
    [
      "Carriage Return";
      "One";
      "Control";
      "Latin Small Letter O With Diaeresis";
      "Euro Sign";
      "Emoji: Grinning Face";
      "Hebrew Letter Dalet With Dagesh";
    ]
    (List.map (function `String s -> s | _ -> "") names)

let jcs_rejects () =
  Alcotest.(check bool)
    "duplicate member" true
    (Result.is_error
       (Jcs.encode_result (`Assoc [ ("a", `Int 1); ("a", `Int 2) ])));
  Alcotest.(check bool)
    "NaN" true
    (Result.is_error (Jcs.encode_result (`Float Float.nan)));
  Alcotest.(check bool)
    "bad UTF-8" true
    (Result.is_error (Jcs.encode_result (`String "\xff")))

(* base64url *)

let b64 () =
  List.iter
    (fun (raw, enc) ->
      check_str "encode" enc (B64url.encode raw);
      check_str "decode" raw (ok (B64url.decode enc)))
    [
      ("", ""); ("f", "Zg"); ("fo", "Zm8"); ("foo", "Zm9v"); ("\xfb\xff", "-_8");
    ];
  Alcotest.(check bool)
    "padding refused" true
    (Result.is_error (B64url.decode "Zg=="));
  Alcotest.(check bool)
    "non-canonical refused" true
    (Result.is_error (B64url.decode "Zh"))

(* Ed25519, RFC 8032 section 7.1 test 1 *)

let ed25519 () =
  let k =
    Crypto.signing_key_of_seed_exn
      (unhex "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
  in
  check_str "public"
    "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
    (Hex.encode k.pub);
  let s = Crypto.sign k "" in
  check_str "signature"
    "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"
    (Hex.encode s);
  Alcotest.(check bool)
    "verifies" true
    (Crypto.verify ~pub:k.pub ~signature:s "");
  Alcotest.(check bool)
    "other message" false
    (Crypto.verify ~pub:k.pub ~signature:s "x")

(* BIP39, the reference vectors (passphrase TREZOR) *)

let bip39 () =
  List.iter
    (fun (entropy, phrase, seed) ->
      check_str "phrase" phrase (Phrase.of_entropy (unhex entropy));
      check_str "valid" phrase (ok (Phrase.validate phrase));
      check_str "seed" seed
        (Hex.encode (Phrase.seed ~passphrase:"TREZOR" phrase)))
    [
      ( "00000000000000000000000000000000",
        "abandon abandon abandon abandon abandon abandon abandon abandon \
         abandon abandon abandon about",
        "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04"
      );
      ( "0000000000000000000000000000000000000000000000000000000000000000",
        "abandon abandon abandon abandon abandon abandon abandon abandon \
         abandon abandon abandon abandon abandon abandon abandon abandon \
         abandon abandon abandon abandon abandon abandon abandon art",
        "bda85446c68413707090a52022edd26a1c9462295029f2e60cd7c4f2bbd3097170af7a4d73245cafa9c3cca8d561a7c3de6f5d4a10be8ed2a5e608d68f92fcc8"
      );
      ( "f585c11aec520db57dd353c69554b21a89b20fb0650966fa0a9d6f74fd989d8f",
        "void come effort suffer camp survey warrior heavy shoot primary \
         clutch crush open amazing screen patrol group space point ten exist \
         slush involve unfold",
        "01f5bced59dec48e362f2c45b5de68b9fd6c92c6634f44d6d40aab69056506f0e35524a518034ddc1192e1dacd32c1ed3eaa3c3b131c88ed8e7e54c49a5d0998"
      );
    ];
  Alcotest.(check bool)
    "bad checksum" true
    (Result.is_error
       (Phrase.validate
          "abandon abandon abandon abandon abandon abandon abandon abandon \
           abandon abandon abandon abandon"));
  let p = Phrase.generate () in
  let a = ok (Phrase.derive p)
  and b = ok (Phrase.derive ("  " ^ String.uppercase_ascii p ^ "\n")) in
  check_str "identity is a function of the phrase" (Keys.public a.identity)
    (Keys.public b.identity);
  check_str "encryption too"
    (Keys.encryption_public a.encryption)
    (Keys.encryption_public b.encryption);
  Alcotest.(check bool)
    "24 words" true
    (List.length (String.split_on_char ' ' p) = 24)

(* Envelopes and request signing *)

let envelopes () =
  let k = Crypto.generate_signing_key () in
  let body = `Assoc [ ("text", `String "hello"); ("n", `Int 3) ] in
  let sg = Envelope.create ~key:k ~seq:1 ~epoch:0 ~kind:"summary" body in
  Alcotest.(check bool) "verifies" true (Envelope.verify sg = Ok ());
  let rt =
    ok
      (Result.map_error Envelope.error_message
         (Envelope.signed_of_json
            (Yojson.Safe.from_string
               (Yojson.Safe.to_string (Envelope.signed_to_json sg)))))
  in
  check_str "hash survives a round trip"
    (Envelope.hash sg.envelope)
    (Envelope.hash rt.envelope);
  Alcotest.(check bool)
    "dropped body still verifies" true
    (Envelope.verify { sg with body = None } = Ok ());
  Alcotest.(check bool)
    "tampered body" true
    (Result.is_error
       (Envelope.verify
          { sg with body = Some (`Assoc [ ("text", `String "bye") ]) }));
  Alcotest.(check bool)
    "tampered seq" true
    (Result.is_error
       (Envelope.verify { sg with envelope = { sg.envelope with seq = 2 } }));
  Alcotest.(check bool)
    "whitespace in the body does not matter" true
    (Envelope.verify
       {
         sg with
         body =
           Some (Yojson.Safe.from_string {| { "n" : 3 , "text" : "hello" } |});
       }
    = Ok ())

let request_signing () =
  let k = Crypto.generate_signing_key () in
  let seen = Hashtbl.create 4 in
  let check ?(now = Unix.gettimeofday ()) headers ~path ~body =
    Request_sign.verify ~skew_seconds:3600 ~now
      ~seen:(fun ~key ~nonce ->
        let s = Hashtbl.mem seen (key, nonce) in
        Hashtbl.replace seen (key, nonce) ();
        s)
      ~meth:"POST" ~path ~body headers
  in
  let h =
    Request_sign.headers ~key:k ~meth:"POST" ~path:"/v0/envelopes" ~body:"{}" ()
  in
  Alcotest.(check bool)
    "verifies" true
    (check h ~path:"/v0/envelopes" ~body:"{}" = Ok (Keys.public k));
  Alcotest.(check bool)
    "replayed nonce" true
    (check h ~path:"/v0/envelopes" ~body:"{}"
    = Error Request_sign.Replayed_nonce);
  let h2 =
    Request_sign.headers ~key:k ~meth:"POST" ~path:"/v0/envelopes" ~body:"{}" ()
  in
  Alcotest.(check bool)
    "other body" true
    (check h2 ~path:"/v0/envelopes" ~body:"{ }"
    = Error Request_sign.Bad_signature);
  let h3 =
    Request_sign.headers ~key:k ~meth:"POST" ~path:"/v0/envelopes" ~body:"{}" ()
  in
  Alcotest.(check bool)
    "inside the window" true
    (check
       ~now:(Unix.gettimeofday () +. 3500.)
       h3 ~path:"/v0/envelopes" ~body:"{}"
    |> Result.is_ok);
  let h4 =
    Request_sign.headers ~key:k ~meth:"POST" ~path:"/v0/envelopes" ~body:"{}" ()
  in
  Alcotest.(check bool)
    "outside the window" true
    (check
       ~now:(Unix.gettimeofday () +. 3700.)
       h4 ~path:"/v0/envelopes" ~body:"{}"
    = Error Request_sign.Stale_request);
  check_str "signed string"
    "DIGESTIF-REQUEST-V0\n\
     GET\n\
     /v0/envelopes?after=0&limit=500\n\
     T\n\
     N\n\
     e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    (Request_sign.signed_string ~meth:"get"
       ~path:"/v0/envelopes?after=0&limit=500" ~timestamp:"T" ~nonce:"N"
       ~body:"")

(* A circle of two nodes and two relays *)

let tmpdir () =
  let d =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "digestif-test-%d-%s" (Unix.getpid ())
         (B64url.encode (Crypto.random 6)))
  in
  d

type circle = {
  relays : Fake_relay.t list;
  net : Relay_client.transport;
  host : Node.t;
  roman : Node.t;
  roman_phrase : string;
  root : string;
}

let in_hours h = Time_fmt.of_unix (Unix.gettimeofday () +. (h *. 3600.))
let new_node () = Node.open_ ~keystore:(Keystore.memory ()) (tmpdir ())

let make_circle ?(expires = in_hours 72.) ?(expect_join = true) () =
  let host = new_node () and roman = new_node () in
  let host_phrase = Phrase.generate () and roman_phrase = Phrase.generate () in
  let hd = ok (Node.init host ~phrase:host_phrase) in
  let rd = ok (Node.init roman ~phrase:roman_phrase) in
  let invite = Crypto.generate_signing_key () in
  let dinner =
    Bodies.dinner_json
      {
        host = Keys.public hd.identity;
        date = "2026-10-27";
        label = "AI Dinner 2";
        guests =
          [
            {
              name = "Roman";
              invite_key = Keys.public invite;
              expires_at = expires;
            };
          ];
        relays = [ "https://a.test"; "https://b.test" ];
      }
  in
  let root, _ = ok (Node.write host ~kind:"dinner" dinner) in
  Node.set_root host root;
  Node.set_root roman root;
  let relays =
    [
      Fake_relay.create ~url:"https://a.test" ~root;
      Fake_relay.create ~url:"https://b.test" ~root;
    ]
  in
  let net = Fake_relay.network relays in
  List.iter
    (fun (r : Fake_relay.t) ->
      Log.add_relay host.log r.url;
      Log.add_relay roman.log r.url)
    relays;
  ignore (ok (Sync.sync ~transport:net host));
  let device = ok (Node.device_key roman) in
  let join =
    Bodies.make_join ~invite_key:invite ~dinner_hash:root ~identity:rd.identity
      ~device
  in
  let sg = Envelope.create ~key:invite ~seq:1 ~epoch:0 ~kind:"join" join in
  List.iter
    (fun (r : Fake_relay.t) ->
      match Relay_client.append net ~base:r.url ~key:None sg with
      | Ok _ -> ()
      | Error e ->
          if expect_join then Alcotest.fail (Relay_client.error_to_string e))
    relays;
  ignore (ok (Node.import roman sg));
  ignore (ok (Sync.sync ~transport:net roman));
  ignore (ok (Sync.sync ~transport:net host));
  { relays; net; host; roman; roman_phrase; root }

let relay c url = List.find (fun (r : Fake_relay.t) -> r.url = url) c.relays
let summary text = `Assoc [ ("text", `String text) ]

let faults_of (n : Node.t) kind =
  List.filter (fun (f : Log.fault) -> f.kind = kind) (Log.open_faults n.log)

let admission () =
  let c = make_circle () in
  let f = Node.fold c.roman in
  Alcotest.(check int) "a join increments the epoch" 1 f.epoch;
  let roman_device = Option.get (Log.get_config c.roman.log Node.k_device) in
  Alcotest.(check int)
    "the newcomer's join epoch" 1
    (Option.get (Fold.find f roman_device)).join_epoch;
  Alcotest.(check (list (pair string string))) "nothing refused" [] f.rejected;
  let hf = Node.fold c.host in
  Alcotest.(check (list string)) "both nodes fold the same" f.applied hf.applied

(* A relay with an empty database refuses the first read, because nothing admits this node there yet;
   the push that follows carries the founding dinner, which admits it. The same sync reads again, so
   the bootstrap reports no error and holds what it pushed. *)
let fresh_relay_bootstrap () =
  let host = new_node () in
  let hd = ok (Node.init host ~phrase:(Phrase.generate ())) in
  let dinner =
    Bodies.dinner_json
      {
        host = Keys.public hd.identity;
        date = "2026-10-27";
        label = "AI Dinner 2";
        guests = [];
        relays = [ "https://a.test" ];
      }
  in
  let root, _ = ok (Node.write host ~kind:"dinner" dinner) in
  Node.set_root host root;
  let a = Fake_relay.create ~url:"https://a.test" ~root in
  Log.add_relay host.log a.url;
  let r = ok (Sync.sync ~transport:(Fake_relay.network [ a ]) host) in
  let rr = List.hd r.relays in
  Alcotest.(check (option string)) "no error after the bootstrap" None rr.error;
  Alcotest.(check int) "pushed the dinner" 1 rr.pushed;
  Alcotest.(check int) "read it back in the same sync" 1 rr.fetched;
  Alcotest.(check (option string))
    "the relay list shows no error" None
    (List.hd (Log.relays host.log)).last_error

(* A member who starts a relay publishes a relay message, and every node adds it (design.md, Two
   relays to start); a relay message from outside the circle adds nothing, and a relay a node removed
   stays removed. *)
let relay_message_adds_relay () =
  let c = make_circle () in
  let urls (n : Node.t) =
    List.map (fun (r : Log.relay_row) -> r.url) (Log.relays n.log)
  in
  let third = Fake_relay.create ~url:"https://c.test" ~root:c.root in
  let net = Fake_relay.network (third :: c.relays) in
  (match ok (Node.add_own_relay c.roman third.url) with
  | Some _ -> ()
  | None -> Alcotest.fail "published no relay message");
  Alcotest.(check (option string))
    "a relay the circle names is not announced twice" None
    (ok (Node.add_own_relay c.roman third.url));
  ignore (ok (Sync.sync ~transport:net c.roman));
  (* A key outside the circle names a relay too. *)
  let stranger = Crypto.generate_signing_key () in
  ignore
    (Fake_relay.force (relay c "https://a.test")
       (Envelope.create ~key:stranger ~seq:1 ~epoch:1 ~kind:"relay"
          (Bodies.make_relay ~url:"https://evil.test" ~mailer:false ())));
  ignore (ok (Sync.sync ~transport:net c.host));
  Alcotest.(check (list string))
    "the host added the member's relay, not the stranger's"
    [ "https://a.test"; "https://b.test"; "https://c.test" ]
    (urls c.host);
  ignore (ok (Sync.sync ~transport:net c.host));
  Alcotest.(check bool)
    "and reads and writes it" true
    ((List.find
        (fun (r : Log.relay_row) -> r.url = third.url)
        (Log.relays c.host.log))
       .last_sync_at <> None);
  Log.remove_relay c.host.log third.url;
  ignore (ok (Sync.sync ~transport:net c.host));
  Alcotest.(check (list string))
    "a removed relay stays removed"
    [ "https://a.test"; "https://b.test" ]
    (urls c.host)

(* A member's relay message reaches every node, so its URL must be a public https relay. *)
let unsafe_relay_message () =
  let c = make_circle () in
  let net = Fake_relay.network c.relays in
  Alcotest.(check bool)
    "--mine refuses a relay no other node would take" true
    (Result.is_error (Node.add_own_relay c.roman "http://127.0.0.1:7420"));
  ignore
    (ok
       (Node.write c.roman ~kind:"relay"
          (Bodies.make_relay ~url:"http://127.0.0.1:7420" ~mailer:false ())));
  ignore (ok (Sync.sync ~transport:net c.roman));
  ignore (ok (Sync.sync ~transport:net c.host));
  Alcotest.(check (list string))
    "an admitted member's http relay is not added"
    [ "https://a.test"; "https://b.test" ]
    (List.map (fun (r : Log.relay_row) -> r.url) (Log.relays c.host.log));
  Alcotest.(check bool)
    "and is a fault" true
    (List.exists
       (fun (f : Log.fault) -> f.kind = "unsafe_relay")
       (Log.open_faults c.host.log))

let relay_urls_from_circle () =
  List.iter
    (fun (url, want) ->
      Alcotest.(check bool) url want (Relay_url.from_circle url))
    [
      ("https://dinners.digestif.io", true);
      ("https://dinners.rcherkasov.workers.dev/", true);
      ("https://relay.example.com:8443/v0", true);
      ("https://8.8.8.8", true);
      ("http://dinners.digestif.io", false);
      ("file:///etc/passwd", false);
      ("https://localhost:8787", false);
      ("https://app.localhost", false);
      ("https://printer.local", false);
      ("https://intranet", false);
      ("https://127.0.0.1", false);
      ("https://10.0.0.5", false);
      ("https://172.20.1.1", false);
      ("https://192.168.1.10", false);
      ("https://169.254.169.254", false);
      ("https://100.100.1.1", false);
      ("https://[::1]:8787", false);
      ("https://user@evil.example.com", false);
      ("https://", false);
    ]

let unknown_spent_expired_invites () =
  let c = make_circle () in
  let rd = ok (Phrase.derive c.roman_phrase) in
  let device = Crypto.generate_signing_key () in
  (* A second join with the spent invite. *)
  let stranger = Crypto.generate_signing_key () in
  let join_with invite =
    Envelope.create ~key:invite ~seq:1 ~epoch:1 ~kind:"join"
      (Bodies.make_join ~invite_key:invite ~dinner_hash:c.root
         ~identity:rd.identity ~device)
  in
  let a = relay c "https://a.test" in
  (match
     Relay_client.append c.net ~base:a.url ~key:None (join_with stranger)
   with
  | Error e ->
      Alcotest.(check (list string))
        "unknown invite refused" [ "not_admitted" ]
        (Relay_client.error_codes e)
  | Ok _ -> Alcotest.fail "accepted a join from an unknown invite key");
  let expired = make_circle ~expires:(in_hours (-1.)) ~expect_join:false () in
  Alcotest.(check int)
    "the relays refused it" 1
    (List.length (relay expired "https://a.test").items);
  (* The guest was never admitted, so it read nothing; hand the host the join to fold. *)
  List.iter
    (fun (r : Log.row) -> ignore (ok (Node.import expired.host r.signed)))
    (Log.of_kind expired.roman.log "join");
  let f = Node.fold expired.host in
  Alcotest.(check int) "expired invite admits nobody" 0 f.epoch;
  Alcotest.(check bool)
    "and says why" true
    (List.exists (fun (_, m) -> m = "invite expired") f.rejected)

let divergent_histories_merge () =
  let c = make_circle () in
  let a = relay c "https://a.test" and b = relay c "https://b.test" in
  b.down <- true;
  let h1, _ = ok (Node.write c.host ~kind:"summary" (summary "host on A")) in
  ignore (Sync.sync ~transport:c.net c.host);
  b.down <- false;
  a.down <- true;
  let r1, _ = ok (Node.write c.roman ~kind:"summary" (summary "roman on B")) in
  ignore (Sync.sync ~transport:c.net c.roman);
  a.down <- false;
  ignore (ok (Sync.sync ~transport:c.net c.host));
  ignore (ok (Sync.sync ~transport:c.net c.roman));
  List.iter
    (fun (n : Node.t) ->
      Alcotest.(check bool)
        "holds both" true
        (Log.find n.log h1 <> None && Log.find n.log r1 <> None))
    [ c.host; c.roman ];
  let hashes (n : Node.t) =
    List.sort compare (List.map (fun (r : Log.row) -> r.hash) (Log.all n.log))
  in
  Alcotest.(check (list string)) "the same log" (hashes c.host) (hashes c.roman);
  Alcotest.(check (list string))
    "the same fold" (Node.fold c.host).applied (Node.fold c.roman).applied;
  let feed (n : Node.t) =
    List.map (fun (r : Log.row) -> r.hash) (View.feed n.log (Node.fold n))
  in
  Alcotest.(check (list string)) "the same feed" (feed c.host) (feed c.roman);
  Alcotest.(check int) "both notes in it" 2 (List.length (feed c.host));
  (* Each relay was repaired with the envelope it missed. *)
  List.iter
    (fun (r : Fake_relay.t) ->
      Alcotest.(check bool)
        ("repaired " ^ r.url) true
        (List.exists (fun (s : Fake_relay.stored) -> s.hash = h1) r.items
        && List.exists (fun (s : Fake_relay.stored) -> s.hash = r1) r.items))
    c.relays

let gap_backfill () =
  let c = make_circle () in
  let hs =
    List.init 3 (fun i ->
        fst (ok (Node.write c.host ~kind:"summary" (summary (string_of_int i)))))
  in
  ignore (ok (Sync.sync ~transport:c.net c.host));
  let b = relay c "https://b.test" in
  Fake_relay.remove b (List.nth hs 1);
  (* Roman reads only B first: the hole is a gap. *)
  Log.remove_relay c.roman.log "https://a.test";
  ignore (ok (Sync.sync ~transport:c.net c.roman));
  Alcotest.(check int) "gap detected" 1 (List.length (faults_of c.roman "gap"));
  Log.add_relay c.roman.log "https://a.test";
  ignore (ok (Sync.sync ~transport:c.net c.roman));
  Alcotest.(check int)
    "backfilled from A" 0
    (List.length (faults_of c.roman "gap"));
  Alcotest.(check bool)
    "holds the missing one" true
    (Log.find c.roman.log (List.nth hs 1) <> None);
  Alcotest.(check (list string))
    "no other faults" []
    (List.map (fun (f : Log.fault) -> f.kind) (Log.open_faults c.roman.log))

let fork_surfaced () =
  let c = make_circle () in
  let h1, sg =
    ok (Node.write c.host ~kind:"summary" (summary "the real one"))
  in
  ignore (ok (Sync.sync ~transport:c.net c.host));
  let key = ok (Node.device_key c.host) in
  let forked =
    Envelope.create ~key ~seq:sg.envelope.seq ?prev:sg.envelope.prev
      ~epoch:sg.envelope.epoch ~kind:"summary"
      (summary "a second history")
  in
  let b = relay c "https://b.test" in
  (match Relay_client.append c.net ~base:b.url ~key:(Some key) forked with
  | Error e ->
      Alcotest.(check (list string))
        "the relay refuses a fork" [ "fork" ]
        (Relay_client.error_codes e)
  | Ok _ -> Alcotest.fail "fork accepted");
  (* A relay that does not enforce it serves both; the node surfaces the fault and keeps both. *)
  Fake_relay.remove b h1;
  ignore (Fake_relay.force b forked);
  ignore (ok (Sync.sync ~transport:c.net c.roman));
  Alcotest.(check int)
    "fork surfaced" 1
    (List.length (faults_of c.roman "fork"));
  Alcotest.(check (list string))
    "neither side is believed" []
    (List.map
       (fun (r : Log.row) -> r.hash)
       (View.feed c.roman.log (Node.fold c.roman)))

let duplicates_idempotent () =
  let c = make_circle () in
  let _, sg = ok (Node.write c.host ~kind:"summary" (summary "once")) in
  ignore (ok (Sync.sync ~transport:c.net c.host));
  let key = ok (Node.device_key c.host) in
  let a = relay c "https://a.test" in
  let before = List.length a.items in
  (match Relay_client.append c.net ~base:a.url ~key:(Some key) sg with
  | Ok r -> Alcotest.(check bool) "duplicate" true r.duplicate
  | Error e -> Alcotest.fail (Relay_client.error_to_string e));
  Alcotest.(check int) "stored once" before (List.length a.items);
  let n = Log.count c.roman.log in
  ignore (ok (Sync.sync ~transport:c.net c.roman));
  ignore (ok (Sync.sync ~transport:c.net c.roman));
  Alcotest.(check int) "the node stores it once" (n + 1) (Log.count c.roman.log)

let feed_hashes (n : Node.t) =
  List.map (fun (r : Log.row) -> r.hash) (View.feed n.log (Node.fold n))

(* created_at [ms] milliseconds before [at], the clock a thief sets. *)
let before_ms at ms =
  Time_fmt.of_unix
    (Option.get (Time_fmt.to_unix at) -. (float_of_int ms /. 1000.))

let push_all c (sg : Envelope.signed) ~key =
  List.iter
    (fun (rl : Fake_relay.t) ->
      match Relay_client.append c.net ~base:rl.url ~key:(Some key) sg with
      | Ok _ -> ()
      | Error e -> Alcotest.fail (Relay_client.error_to_string e))
    c.relays

let revoke_parts body =
  ok (Result.map_error (fun m -> m) (Bodies.parse_revoke body))

(* node.revocation.ignored-from-revoke-forward: a relay that never saw the revoke serves the revoked
   device's notes past after_seq, one backdated before the revoke; the node keeps the notes at or
   below after_seq and ignores both. *)
let revocation () =
  let c = make_circle () in
  let a = relay c "https://a.test" and b = relay c "https://b.test" in
  let roman_device = ok (Node.device_key c.roman) in
  let before, _ = ok (Node.write c.roman ~kind:"summary" (summary "before")) in
  let only_b, only_b_sg =
    ok (Node.write c.roman ~kind:"summary" (summary "before, on B only"))
  in
  ignore (ok (Sync.sync ~transport:c.net c.roman));
  Fake_relay.remove a only_b;
  let identity = ok (Node.identity_from_phrase c.roman c.roman_phrase) in
  (* Roman lost the laptop: a new machine re-derives the identity, signs its own key in, reads every
     relay, and revokes the old device. *)
  let laptop = new_node () in
  Node.set_root laptop c.root;
  ignore (ok (Node.init laptop ~phrase:c.roman_phrase));
  List.iter (fun (r : Fake_relay.t) -> Log.add_relay laptop.log r.url) c.relays;
  let new_device = ok (Node.device_key laptop) in
  ignore
    (ok
       (Node.write laptop ~kind:"device"
          (Bodies.make_device ~identity ~key:(Keys.public new_device)
             ~role:Device)));
  (* The first sync's reads are refused (the new key is not admitted yet), and it pushes the device
     message unsigned, as a bootstrap append; the second reads every relay. *)
  ignore (ok (Sync.sync ~transport:c.net laptop));
  ignore (ok (Sync.sync ~transport:c.net laptop));
  let body =
    ok (Node.revoke_body laptop ~by:identity ~target:(Keys.public roman_device))
  in
  let r = revoke_parts body in
  Alcotest.(check (list (pair string int)))
    "after_seq is the old device's last honest seq, read from both relays"
    [ (Keys.public roman_device, only_b_sg.envelope.seq) ]
    r.after_seq;
  let _, revoke_sg = ok (Node.write laptop ~kind:"revoke" body) in
  (* Relay A sees the revoke; relay B never does. *)
  (match
     Relay_client.append c.net ~base:a.url ~key:(Some new_device) revoke_sg
   with
  | Ok _ -> ()
  | Error e -> Alcotest.fail (Relay_client.error_to_string e));
  let revoked_at = revoke_sg.envelope.created_at in
  let cutoff = only_b_sg.envelope.seq in
  let late =
    Envelope.create ~key:roman_device ~seq:(cutoff + 1) ~epoch:1 ~kind:"summary"
      (summary "after")
  in
  (match
     Relay_client.append c.net ~base:a.url ~key:(Some roman_device) late
   with
  | Error e ->
      Alcotest.(check (list string))
        "relay A refuses a revoked key" [ "not_admitted" ]
        (Relay_client.error_codes e)
  | Ok _ -> Alcotest.fail "revoked key accepted");
  ignore (Fake_relay.force b late);
  (* Earlier than the revoke and later than the device's admission: the one window a created_at
     order would read it in. *)
  let backdated =
    Envelope.create ~key:roman_device ~seq:(cutoff + 2)
      ~created_at:(before_ms revoked_at 1) ~epoch:1 ~kind:"summary"
      (summary "backdated by a thief")
  in
  ignore (Fake_relay.force b backdated);
  ignore (ok (Sync.sync ~transport:c.net c.host));
  let f = Node.fold c.host in
  let k = Option.get (Fold.find f (Keys.public roman_device)) in
  Alcotest.(check bool)
    "the fold marks the device revoked" true (k.revoked_by <> None);
  Alcotest.(check (option int)) "the cutoff" (Some cutoff) k.after_seq;
  let feed = feed_hashes c.host in
  Alcotest.(check bool)
    "the note from before the revoke stays" true (List.mem before feed);
  Alcotest.(check bool)
    "the note at after_seq, which only relay B holds, stays" true
    (List.mem only_b feed);
  Alcotest.(check bool)
    "the note from after the revoke is ignored" false
    (List.mem (Envelope.hash late.envelope) feed);
  Alcotest.(check bool)
    "the note past after_seq is ignored though its created_at is before the \
     revoke"
    false
    (List.mem (Envelope.hash backdated.envelope) feed)

(* node.revocation.mail-read-by-listed-hashes: a relay that never saw the revoke serves a revoked
   mail key's answers the revoke does not list, one backdated before the revoke; the node keeps the
   answers mail_read lists and ignores both. *)
let mail_revocation () =
  let c = make_circle () in
  let a = relay c "https://a.test" and b = relay c "https://b.test" in
  let identity = ok (Node.identity_from_phrase c.roman c.roman_phrase) in
  let mail = ok (Node.mail_key c.roman) in
  ignore
    (ok
       (Node.write c.roman ~kind:"device"
          (Bodies.make_device ~identity ~key:(Keys.public mail) ~role:Mail)));
  let ask, _ = ok (Node.write c.host ~kind:"question" (summary "the ask")) in
  ignore (ok (Sync.sync ~transport:c.net c.host));
  ignore (ok (Sync.sync ~transport:c.net c.roman));
  let epoch = (Node.fold c.roman).epoch in
  let answer ?created_at seq text =
    Envelope.create ~key:mail ~seq ~prev:ask ?created_at ~epoch ~kind:"answer"
      (summary text)
  in
  let honest = answer 7 "honest" in
  push_all c honest ~key:mail;
  let only_b = answer 3 "honest, on B only" in
  (match Relay_client.append c.net ~base:b.url ~key:(Some mail) only_b with
  | Ok _ -> ()
  | Error e -> Alcotest.fail (Relay_client.error_to_string e));
  ignore (ok (Sync.sync ~transport:c.net c.roman));
  let body =
    ok (Node.revoke_body c.roman ~by:identity ~target:(Keys.public mail))
  in
  let r = revoke_parts body in
  let honest_h = Envelope.hash honest.envelope
  and only_b_h = Envelope.hash only_b.envelope in
  Alcotest.(check (list (pair string (list string))))
    "mail_read lists every answer the node holds, from both relays"
    [ (Keys.public mail, List.sort compare [ honest_h; only_b_h ]) ]
    r.mail_read;
  Alcotest.(check (list (pair string int)))
    "a mail key has no after_seq" [] r.after_seq;
  let _, revoke_sg = ok (Node.write c.roman ~kind:"revoke" body) in
  let device = ok (Node.device_key c.roman) in
  (match Relay_client.append c.net ~base:a.url ~key:(Some device) revoke_sg with
  | Ok _ -> ()
  | Error e -> Alcotest.fail (Relay_client.error_to_string e));
  let revoked_at = revoke_sg.envelope.created_at in
  let after = answer 9 "after the revoke" in
  ignore (Fake_relay.force b after);
  (* A seq the honest key never used and a created_at before the revoke: an order cutoff would read
     it, and no seq cutoff can bound a chainless key. *)
  let backdated =
    answer ~created_at:(before_ms revoked_at 1) 1 "backdated by a thief"
  in
  ignore (Fake_relay.force b backdated);
  ignore (ok (Sync.sync ~transport:c.net c.host));
  let f = Node.fold c.host in
  Alcotest.(check bool)
    "the fold marks the mail key revoked" true
    ((Option.get (Fold.find f (Keys.public mail))).revoked_by <> None);
  let feed = feed_hashes c.host in
  Alcotest.(check bool)
    "the answer mail_read lists stays" true (List.mem honest_h feed);
  Alcotest.(check bool)
    "the listed answer only relay B holds stays" true (List.mem only_b_h feed);
  Alcotest.(check bool)
    "the answer from after the revoke is ignored" false
    (List.mem (Envelope.hash after.envelope) feed);
  Alcotest.(check bool)
    "the unlisted answer is ignored though its created_at is before the revoke"
    false
    (List.mem (Envelope.hash backdated.envelope) feed)

let revoke_json ~by ~target ~after_seq ~mail_read =
  let b = Keys.public by in
  let claim =
    `Assoc
      ([ ("target", `String target); ("by", `String b) ]
      @ (match after_seq with Some v -> [ ("after_seq", v) ] | None -> [])
      @ match mail_read with Some v -> [ ("mail_read", v) ] | None -> [])
  in
  match claim with
  | `Assoc f -> `Assoc (f @ [ ("signature", `String (Keys.sign_json by claim)) ])
  | j -> j

(* parse_revoke refuses what docs/protocol.md calls malformed and the body alone shows. *)
let revoke_shape () =
  let by = Crypto.generate_signing_key () in
  let target = Keys.public (Crypto.generate_signing_key ()) in
  let h = Keys.hash_of_bytes "x" in
  let parses ~after_seq ~mail_read =
    Result.is_ok
      (Bodies.parse_revoke (revoke_json ~by ~target ~after_seq ~mail_read))
  in
  let empty = Some (`Assoc []) in
  Alcotest.(check bool)
    "well formed" true
    (parses
       ~after_seq:(Some (`Assoc [ (target, `Int 4) ]))
       ~mail_read:(Some (`Assoc [ ("m", `List [ `String h ]) ])));
  Alcotest.(check bool)
    "missing after_seq" false
    (parses ~after_seq:None ~mail_read:empty);
  Alcotest.(check bool)
    "missing mail_read" false
    (parses ~after_seq:empty ~mail_read:None);
  Alcotest.(check bool)
    "negative seq" false
    (parses ~after_seq:(Some (`Assoc [ (target, `Int (-1)) ])) ~mail_read:empty);
  Alcotest.(check bool)
    "non-integer seq" false
    (parses
       ~after_seq:(Some (`Assoc [ (target, `Float 1.5) ]))
       ~mail_read:empty);
  Alcotest.(check bool)
    "after_seq not an object" false
    (parses ~after_seq:(Some (`List [])) ~mail_read:empty);
  Alcotest.(check bool)
    "mail_read value not a list" false
    (parses ~after_seq:empty ~mail_read:(Some (`Assoc [ ("m", `String h) ])));
  Alcotest.(check bool)
    "mail_read entry not an envelope hash" false
    (parses ~after_seq:empty
       ~mail_read:(Some (`Assoc [ ("m", `List [ `String "nothash" ]) ])));
  let body =
    Bodies.make_revoke ~by ~target ~after_seq:[ (target, 2) ] ~mail_read:[]
  in
  let r = ok (Bodies.parse_revoke body) in
  Alcotest.(check bool)
    "make_revoke signs the cutoffs" true
    (Bodies.revoke_signature_valid r);
  Alcotest.(check bool)
    "a changed cutoff breaks the signature" false
    (Bodies.revoke_signature_valid { r with after_seq = [ (target, 9) ] })

(* The fold refuses a cutoff naming a key the revoke does not stop, and two revokes of one key leave
   the lower seq cutoff and the hashes both list. *)
let revoke_cutoffs () =
  let c = make_circle () in
  let identity = ok (Node.identity_from_phrase c.roman c.roman_phrase) in
  let roman_device = Keys.public (ok (Node.device_key c.roman)) in
  let spare = Keys.public (Crypto.generate_signing_key ()) in
  let mail = Keys.public (ok (Node.mail_key c.roman)) in
  List.iter
    (fun (key, role) ->
      ignore
        (ok
           (Node.write c.roman ~kind:"device"
              (Bodies.make_device ~identity ~key ~role))))
    [ (spare, Bodies.Device); (mail, Bodies.Mail) ];
  let h n = Keys.hash_of_bytes (string_of_int n) in
  let revoke ~target ~after_seq ~mail_read =
    fst
      (ok
         (Node.write c.roman ~kind:"revoke"
            (Bodies.make_revoke ~by:identity ~target ~after_seq ~mail_read)))
  in
  let names_other =
    revoke ~target:spare ~after_seq:[ (roman_device, 1) ] ~mail_read:[]
  in
  let mail_as_device =
    revoke ~target:mail ~after_seq:[ (mail, 1) ] ~mail_read:[]
  in
  let device_as_mail =
    revoke ~target:spare ~after_seq:[] ~mail_read:[ (spare, []) ]
  in
  ignore (revoke ~target:spare ~after_seq:[ (spare, 5) ] ~mail_read:[]);
  ignore (revoke ~target:spare ~after_seq:[ (spare, 2) ] ~mail_read:[]);
  ignore (revoke ~target:mail ~after_seq:[] ~mail_read:[ (mail, [ h 1; h 2 ]) ]);
  ignore (revoke ~target:mail ~after_seq:[] ~mail_read:[ (mail, [ h 2; h 3 ]) ]);
  let f = Node.fold c.roman in
  let malformed hash =
    match List.assoc_opt hash f.rejected with
    | Some m -> String.starts_with ~prefix:"malformed" m
    | None -> false
  in
  Alcotest.(check bool)
    "after_seq naming a key it does not stop" true (malformed names_other);
  Alcotest.(check bool)
    "after_seq naming a mail key" true (malformed mail_as_device);
  Alcotest.(check bool)
    "mail_read naming a device key" true (malformed device_as_mail);
  Alcotest.(check (option int))
    "the lower cutoff" (Some 2) (Option.get (Fold.find f spare)).after_seq;
  Alcotest.(check (list string))
    "the hashes both list"
    [ h 2 ]
    (Fold.Hashes.elements
       (Option.get (Option.get (Fold.find f mail)).mail_read));
  Alcotest.(check bool)
    "the unnamed device stays in force" true
    ((Option.get (Fold.find f roman_device)).revoked_by = None)

(* An unanswered join ask revokes, and the host's node signs that revoke unattended: the device key
   that wrote the dinner revokes the identity a join on it admitted, as itself, for seven days after
   the join. No other device key may, and not after the window. *)
let host_device_revokes_joiner () =
  let c = make_circle () in
  let host_device = ok (Node.device_key c.host) in
  let roman_identity =
    Keys.public (ok (Phrase.derive c.roman_phrase)).identity
  in
  let roman_device = ok (Node.device_key c.roman) in
  let entry (sg : Envelope.signed) =
    {
      Fold.hash = Envelope.hash sg.envelope;
      envelope = sg.envelope;
      body = sg.body;
    }
  in
  let fold_with n sgs =
    Fold.run ~root:c.root (Log.fold_entries n.Node.log @ List.map entry sgs)
  in
  let revoke_by ?created_at ~seq key =
    let body =
      Bodies.make_revoke ~by:key ~target:roman_identity
        ~after_seq:[ (Keys.public roman_device, 0) ]
        ~mail_read:[]
    in
    Envelope.create ~key ~seq ?created_at ~epoch:1 ~kind:"revoke" body
  in
  let joined_at =
    let join =
      List.find
        (fun (e : Fold.entry) -> e.envelope.kind = "join")
        (Log.fold_entries c.host.log)
    in
    Option.get (Time_fmt.to_unix join.envelope.created_at)
  in
  let in_window = revoke_by ~seq:50 host_device in
  let f = fold_with c.host [ in_window ] in
  Alcotest.(check (list (pair string string))) "nothing refused" [] f.rejected;
  Alcotest.(check bool)
    "the dinner's device key revokes the joiner's identity" true
    ((Option.get (Fold.find f roman_identity)).revoked_by <> None);
  Alcotest.(check bool)
    "and every key under it" true
    ((Option.get (Fold.find f (Keys.public roman_device))).revoked_by <> None);
  let late =
    revoke_by ~seq:50
      ~created_at:
        (Time_fmt.of_unix (joined_at +. Fold.host_device_window +. 60.))
      host_device
  in
  let f = fold_with c.host [ late ] in
  Alcotest.(check (option string))
    "refused past the window" (Some "past the dinner device's revoke window")
    (List.assoc_opt (Envelope.hash late.envelope) f.rejected);
  let not_the_dinners = revoke_by ~seq:50 roman_device in
  let f = fold_with c.host [ not_the_dinners ] in
  Alcotest.(check (option string))
    "refused from a device key that did not write the dinner"
    (Some "by did not write the dinner that admitted the target")
    (List.assoc_opt (Envelope.hash not_the_dinners.envelope) f.rejected);
  (* Through the node and a relay: the body the node signs, accepted by the relay's fold. *)
  let body =
    ok (Node.revoke_body c.host ~by:host_device ~target:roman_identity)
  in
  let _, sg = ok (Node.write c.host ~kind:"revoke" body) in
  push_all c sg ~key:host_device;
  ignore (ok (Sync.sync ~transport:c.net c.roman));
  Alcotest.(check bool)
    "the joiner's node folds its identity revoked" true
    ((Option.get (Fold.find (Node.fold c.roman) roman_identity)).revoked_by
   <> None)

let retract () =
  let c = make_circle () in
  let h, _ = ok (Node.write c.host ~kind:"summary" (summary "oops")) in
  ignore (ok (Sync.sync ~transport:c.net c.host));
  ignore (ok (Sync.sync ~transport:c.net c.roman));
  Alcotest.(check bool)
    "body held" true
    ((Option.get (Log.find c.roman.log h)).signed.body <> None);
  ignore
    (ok (Node.write c.host ~kind:"retract" (Bodies.make_retract ~target:h)));
  ignore (ok (Sync.sync ~transport:c.net c.host));
  ignore (ok (Sync.sync ~transport:c.net c.roman));
  List.iter
    (fun (n : Node.t) ->
      let r = Option.get (Log.find n.log h) in
      Alcotest.(check bool)
        "body dropped" true
        (r.signed.body = None && r.retracted_by <> None);
      Alcotest.(check bool)
        "tombstone verifies" true
        (Envelope.verify r.signed = Ok ()))
    [ c.host; c.roman ];
  (* Roman cannot retract the host's note. *)
  let h2, _ = ok (Node.write c.host ~kind:"summary" (summary "mine")) in
  ignore (ok (Sync.sync ~transport:c.net c.host));
  ignore
    (ok (Node.write c.roman ~kind:"retract" (Bodies.make_retract ~target:h2)));
  ignore (ok (Sync.sync ~transport:c.net c.roman));
  Alcotest.(check bool)
    "not the author's" true
    ((Option.get (Log.find c.roman.log h2)).signed.body <> None);
  Alcotest.(check int)
    "surfaced" 1
    (List.length (faults_of c.roman "retract_not_author"))

let epoch_floor () =
  let c = make_circle () in
  (* Content the host wrote at epoch 0, before Roman joined, is not served to Roman. *)
  let a = relay c "https://a.test" in
  let key = ok (Node.device_key c.host) in
  let old =
    Envelope.create ~key ~seq:2 ~prev:c.root ~epoch:0 ~kind:"summary"
      (summary "before roman")
  in
  ignore (Fake_relay.force a old);
  let n = Log.count c.roman.log in
  ignore (ok (Sync.sync ~transport:c.net c.roman));
  Alcotest.(check int) "nothing from before the join" n (Log.count c.roman.log)

let keystore_file () =
  let dir = tmpdir () in
  let ks = Keystore.insecure_dir dir in
  let k = Crypto.generate_signing_key () in
  ok (Keystore.put_signing_key ks "device" k);
  let back = Option.get (ok (Keystore.get_signing_key ks "device")) in
  check_str "round trip" (Keys.public k) (Keys.public back);
  Alcotest.(check int)
    "owner-only" 0o600
    ((Unix.stat (Filename.concat dir "device.key")).st_perm land 0o777)

let service_files () =
  let plist =
    Service.launchd_plist ~exe:"/usr/local/bin/digestif"
      ~dir:"/Users/x/Library/Application Support/Digestif" ~log_dir:"/tmp/x"
      ~path:"/opt/homebrew/bin:/usr/bin:/bin" ()
  in
  Alcotest.(check bool)
    "plist runs the node" true
    (List.for_all
       (fun s -> Astring_contains.contains plist s)
       [
         "<string>com.digestif.node</string>";
         "<string>run</string>";
         "<string>/Users/x/Library/Application Support/Digestif</string>";
         "<key>PATH</key>\n    <string>/opt/homebrew/bin:/usr/bin:/bin</string>";
       ]);
  let unit =
    Service.systemd_unit ~exe:"/usr/bin/digestif"
      ~dir:"/home/x/.local/share/digestif" ~path:"/home/x/my bin:/usr/bin:/a%b" ()
  in
  Alcotest.(check bool)
    "unit carries the installing PATH" true
    (Astring_contains.contains unit
       "Environment=\"PATH=/home/x/my bin:/usr/bin:/a%%b\"\n");
  Alcotest.(check bool)
    "unit runs the node" true
    (Astring_contains.contains unit
       "ExecStart=/usr/bin/digestif run --data-dir \
        /home/x/.local/share/digestif");
  Alcotest.(check bool)
    "the installed file carries the installing PATH" true
    (Astring_contains.contains
       (Service.plan ~exe:"/usr/bin/digestif" ~dir:"/d" ~path:"/opt/x/bin:/bin"
          ())
         .contents "/opt/x/bin:/bin");
  Alcotest.(check bool)
    "the service can run the supervisor" true
    (Astring_contains.contains
       (Service.systemd_unit ~command:[ "supervise" ]
          ~exe:"/d/good/bin/digestif" ~dir:"/d" ~path:"/bin" ())
       "ExecStart=/d/good/bin/digestif supervise --data-dir /d");
  check_str "quotes a path with a space" "\"/a b\""
    (Service.systemd_quote "/a b")

(* launchd's bootout returns before the job is gone: install waits for the probe to stop finding
   it, and says so when it never does. *)
let service_waits_for_unload () =
  let answers = ref [ 0; 0; 113 ] and calls = ref 0 in
  let run _ =
    incr calls;
    match !answers with
    | c :: rest ->
        answers := rest;
        Ok { Proc.code = c; stdout = ""; stderr = "" }
    | [] -> Ok { Proc.code = 113; stdout = ""; stderr = "" }
  in
  Alcotest.(check bool)
    "gone after two polls" true
    (Result.is_ok (Service.wait_until_gone ~interval:0.0 ~run [| "probe" |]));
  Alcotest.(check int) "polled until gone" 3 !calls;
  let always _ = Ok { Proc.code = 0; stdout = ""; stderr = "" } in
  Alcotest.(check bool)
    "never gone is an error" true
    (Result.is_error
       (Service.wait_until_gone ~timeout:0.05 ~interval:0.01 ~run:always
          [| "probe" |]))

let () =
  Alcotest.run "digestif-core"
    [
      ( "jcs",
        [
          Alcotest.test_case "numbers" `Quick jcs_numbers;
          Alcotest.test_case "RFC example" `Quick jcs_rfc_example;
          Alcotest.test_case "sorting" `Quick jcs_sorting;
          Alcotest.test_case "rejects" `Quick jcs_rejects;
        ] );
      ("encoding", [ Alcotest.test_case "base64url" `Quick b64 ]);
      ( "crypto",
        [
          Alcotest.test_case "ed25519" `Quick ed25519;
          Alcotest.test_case "bip39" `Quick bip39;
        ] );
      ( "envelope",
        [
          Alcotest.test_case "sign and verify" `Quick envelopes;
          Alcotest.test_case "request signing" `Quick request_signing;
        ] );
      ( "circle",
        [
          Alcotest.test_case "admission and epoch" `Quick admission;
          Alcotest.test_case "fresh relay bootstrap" `Quick
            fresh_relay_bootstrap;
          Alcotest.test_case "an unsafe relay message adds nothing" `Quick
            unsafe_relay_message;
          Alcotest.test_case "relay URLs a node takes from the circle" `Quick
            relay_urls_from_circle;
          Alcotest.test_case "relay message adds a relay" `Quick
            relay_message_adds_relay;
          Alcotest.test_case "unknown and expired invites" `Quick
            unknown_spent_expired_invites;
          Alcotest.test_case "divergent histories merge" `Quick
            divergent_histories_merge;
          Alcotest.test_case "gap backfill" `Quick gap_backfill;
          Alcotest.test_case "fork surfaced" `Quick fork_surfaced;
          Alcotest.test_case "duplicates idempotent" `Quick
            duplicates_idempotent;
          Alcotest.test_case "revocation" `Quick revocation;
          Alcotest.test_case "mail key revocation" `Quick mail_revocation;
          Alcotest.test_case "revoke shape" `Quick revoke_shape;
          Alcotest.test_case "revoke cutoffs" `Quick revoke_cutoffs;
          Alcotest.test_case "host device revokes a joiner" `Quick
            host_device_revokes_joiner;
          Alcotest.test_case "retract" `Quick retract;
          Alcotest.test_case "epoch floor" `Quick epoch_floor;
        ] );
      ( "platform",
        [
          Alcotest.test_case "file keystore" `Quick keystore_file;
          Alcotest.test_case "service files" `Quick service_files;
          Alcotest.test_case "service waits for unload" `Quick
            service_waits_for_unload;
        ] );
    ]
