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

(* 2026-11-01T08:50:00Z *)
let offset_instant = 1793523000.

(* DIG-555: the protocol's one time form is the Z form, with or without a fraction. *)
let z_form () =
  let check what expected s =
    Alcotest.(check bool) what expected (Time_fmt.is_z s)
  in
  check "whole seconds" true "2026-12-01T10:00:00Z";
  check "milliseconds" true "2026-12-01T10:00:00.000Z";
  check "one digit of fraction" true "2026-12-01T10:00:00.5Z";
  check "four digits of fraction" false "2026-12-01T10:00:00.1234Z";
  check "seconds of 60" false "2026-12-01T10:00:60Z";
  check "what of_unix writes" true (Time_fmt.of_unix 1793523000.);
  check "an offset" false "2026-12-01T10:00:00+01:00";
  check "an offset of zero" false "2026-12-01T10:00:00+00:00";
  check "no zone" false "2026-12-01T10:00:00";
  check "a bare date" false "2026-12-01";
  check "empty" false "";
  check "a lower case z" false "2026-12-01T10:00:00z";
  check "a bare fraction point" false "2026-12-01T10:00:00.Z";
  check "text after the zone" false "2026-12-01T10:00:00Z ";
  check "a space for the T" false "2026-12-01 10:00:00Z";
  check "a month of 13" false "2026-13-01T10:00:00Z";
  check "an hour of 25" false "2026-12-01T25:00:00Z";
  (* DIG-91: the day is checked against its month, leap years included. *)
  check "the 31st of February" false "2026-02-31T10:00:00Z";
  check "the 29th of February, not a leap year" false "2026-02-29T10:00:00Z";
  check "the 29th of February, a leap year" true "2028-02-29T10:00:00Z";
  check "the 29th of February, 1900" false "1900-02-29T10:00:00Z";
  check "the 29th of February, 2000" true "2000-02-29T10:00:00Z";
  check "the 31st of April" false "2026-04-31T10:00:00Z";
  check "the 30th of April" true "2026-04-30T10:00:00Z";
  check "the 31st of December" true "2026-12-31T10:00:00Z"

let date_time_with_offset () =
  let at offset_minutes t = Time_fmt.of_unix_at_offset ~offset_minutes t in
  Alcotest.(check string)
    "west, a fraction dropped" "2026-11-01T03:50:00-05:00"
    (at (-300) (offset_instant +. 0.9));
  Alcotest.(check string)
    "east, part of an hour" "2026-11-01T14:20:00+05:30" (at 330 offset_instant);
  Alcotest.(check string)
    "UTC has an offset too" "2026-11-01T08:50:00+00:00" (at 0 offset_instant);
  (* The machine's zone, read in a child so the zone stays this process's. A POSIX zone string needs
     no tzdata. *)
  match Unix.fork () with
  | 0 ->
      Unix.putenv "TZ" "EST5EDT,M3.2.0,M11.1.0";
      let summer =
        Time_fmt.of_unix_local (offset_instant -. (120. *. 86400.))
      in
      let winter = Time_fmt.of_unix_local (offset_instant +. (30. *. 86400.)) in
      Unix._exit
        (if
           summer = "2026-07-04T04:50:00-04:00"
           && winter = "2026-12-01T03:50:00-05:00"
         then 0
         else 1)
  | child ->
      let _, status = Unix.waitpid [] child in
      Alcotest.(check bool)
        "the machine's offset at that instant, daylight saving honoured" true
        (status = Unix.WEXITED 0)

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
              admission = None;
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

(* A second relay seeded after the invite window closed (protocol.md, The admission fold): the joins
   relay A accepted in time are refused there when their guests send them, and an admitted node
   replicates them, the join signed with its device key and the self-authored device message
   unsigned. A refusal is a replicate_refused fault and the loop goes on to the next join. *)
let admitted_node_replicates_joins () =
  let host = new_node () and roman = new_node () in
  let hd = ok (Node.init host ~phrase:(Phrase.generate ())) in
  let rd = ok (Node.init roman ~phrase:(Phrase.generate ())) in
  let roman_invite = Crypto.generate_signing_key () in
  let ghost_invite = Crypto.generate_signing_key () in
  let guest name invite =
    {
      Bodies.name;
      invite_key = Keys.public invite;
      expires_at = in_hours (-1.);
      admission = None;
    }
  in
  let dinner =
    Bodies.dinner_json
      {
        host = Keys.public hd.identity;
        date = "2026-11-01";
        label = "AI Dinner 3";
        guests = [ guest "Roman" roman_invite; guest "Ghost" ghost_invite ];
        relays = [ "https://a.test"; "https://b.test" ];
      }
  in
  let root, _ = ok (Node.write host ~kind:"dinner" dinner) in
  Node.set_root host root;
  Node.set_root roman root;
  let a = Fake_relay.create ~url:"https://a.test" ~root in
  let b = Fake_relay.create ~url:"https://b.test" ~root in
  let net = Fake_relay.network [ a; b ] in
  List.iter
    (fun url ->
      Log.add_relay host.log url;
      Log.add_relay roman.log url)
    [ a.url; b.url ];
  ignore (ok (Sync.sync ~transport:net host));
  let join ?(identity = Crypto.generate_signing_key ())
      ?(device = Crypto.generate_signing_key ()) invite hours =
    Envelope.create ~key:invite ~seq:1 ~epoch:0 ~kind:"join"
      ~created_at:(in_hours hours)
      (Bodies.make_join ~invite_key:invite ~dinner_hash:root ~identity ~device)
  in
  (* Relay A took both joins before the invites lapsed. Relay B holds another join for the ghost's
     invite, so it refuses the ghost's join A holds, which this node folds first. *)
  let ghost = join ghost_invite (-2.5) in
  let roman_join =
    join ~identity:rd.identity
      ~device:(ok (Node.device_key roman))
      roman_invite (-2.)
  in
  ignore (Fake_relay.force a ghost);
  ignore (Fake_relay.force a roman_join);
  ignore (Fake_relay.force b (join ghost_invite (-1.2)));
  ignore (ok (Node.import roman roman_join));
  let laptop = Crypto.generate_signing_key () in
  let replacement =
    Envelope.create ~key:laptop ~seq:1 ~epoch:(Fake_relay.fold a).epoch
      ~kind:"device"
      (Bodies.make_device ~identity:rd.identity ~key:(Keys.public laptop)
         ~role:Device)
  in
  ignore (Fake_relay.force a replacement);
  Alcotest.(check bool)
    "relay B refuses the guest's own late join" true
    (Result.is_error (Relay_client.append net ~base:b.url ~key:None roman_join));
  let error_on url (r : Sync.report) =
    (List.find (fun (rr : Sync.relay_report) -> rr.relay = url) r.relays).error
  in
  let before = ok (Sync.sync ~transport:net roman) in
  Alcotest.(check bool)
    "roman's node is not admitted on relay B" true
    (match error_on b.url before with
    | Some e -> Astring_contains.contains e "not_admitted"
    | None -> false);
  let r = ok (Sync.sync ~transport:net host) in
  let rb =
    List.find (fun (rr : Sync.relay_report) -> rr.relay = b.url) r.relays
  in
  Alcotest.(check (option string)) "relay B synced" None rb.error;
  Alcotest.(check int)
    "roman's join and device message replicated" 2 rb.replicated;
  let fb = Fake_relay.fold b in
  let roman_device = Option.get (Log.get_config roman.log Node.k_device) in
  List.iter
    (fun (what, key) ->
      Alcotest.(check bool)
        (what ^ " admitted on relay B")
        true
        (Fold.find fb key <> None))
    [
      ("roman's identity", Keys.public rd.identity);
      ("roman's device", roman_device);
      ("roman's replacement laptop", Keys.public laptop);
    ];
  Alcotest.(check (list string))
    "the refused join is a replicate_refused fault"
    [ Keys.public ghost_invite ]
    (List.map
       (fun (f : Log.fault) -> f.author)
       (faults_of host "replicate_refused"));
  Alcotest.(check bool)
    "and is still held, never dropped" true
    (Log.find host.log (Envelope.hash ghost.envelope) <> None);
  let again = ok (Sync.sync ~transport:net host) in
  Alcotest.(check int)
    "nothing left to replicate" 0
    (List.find (fun (rr : Sync.relay_report) -> rr.relay = b.url) again.relays)
      .replicated;
  let after = ok (Sync.sync ~transport:net roman) in
  Alcotest.(check (option string))
    "roman's next sync reads relay B" None (error_on b.url after)

(* Replication runs once every relay has been read: a join only the relay read LAST holds reaches
   the relay read first in the same sync. Relays are read in URL order, so the join sits on z. *)
let replicates_whatever_the_relay_order () =
  let host = new_node () and roman = new_node () in
  let hd = ok (Node.init host ~phrase:(Phrase.generate ())) in
  let rd = ok (Node.init roman ~phrase:(Phrase.generate ())) in
  let invite = Crypto.generate_signing_key () in
  let dinner =
    Bodies.dinner_json
      {
        host = Keys.public hd.identity;
        date = "2026-11-01";
        label = "AI Dinner 3";
        guests =
          [
            {
              Bodies.name = "Roman";
              invite_key = Keys.public invite;
              expires_at = in_hours (-1.);
              admission = None;
            };
          ];
        relays = [ "https://a.test"; "https://z.test" ];
      }
  in
  let root, _ = ok (Node.write host ~kind:"dinner" dinner) in
  Node.set_root host root;
  let a = Fake_relay.create ~url:"https://a.test" ~root in
  let z = Fake_relay.create ~url:"https://z.test" ~root in
  let net = Fake_relay.network [ a; z ] in
  List.iter (fun url -> Log.add_relay host.log url) [ a.url; z.url ];
  ignore (ok (Sync.sync ~transport:net host));
  let roman_join =
    Envelope.create ~key:invite ~seq:1 ~epoch:0 ~kind:"join"
      ~created_at:(in_hours (-2.))
      (Bodies.make_join ~invite_key:invite ~dinner_hash:root
         ~identity:rd.identity
         ~device:(ok (Node.device_key roman)))
  in
  ignore (Fake_relay.force z roman_join);
  let r = ok (Sync.sync ~transport:net host) in
  Alcotest.(check int)
    "the join relay z holds is replicated to relay a, read before it" 1
    (List.find (fun (rr : Sync.relay_report) -> rr.relay = a.url) r.relays)
      .replicated;
  Alcotest.(check bool)
    "roman's identity admitted on relay a" true
    (Fold.find (Fake_relay.fold a) (Keys.public rd.identity) <> None)

(* A later dinner whose host's node reached only relay A and then stopped syncing: relay B lacks the
   dinner, so it would refuse every join naming it. Another admitted node replicates the dinner
   unsigned, ahead of the join. With [~later] the host's device had already put a later envelope on
   B, so B refuses the dinner as a sequence_regression and the join for want of it. *)
let replicate_unpushed_dinner ~later =
  let c = make_circle () in
  let a = relay c "https://a.test" and b = relay c "https://b.test" in
  let sam_invite = Crypto.generate_signing_key () in
  let dinner =
    Bodies.dinner_json
      {
        host = Option.get (Log.get_config c.host.log Node.k_identity);
        date = "2026-11-12";
        label = "AI Dinner 3";
        guests =
          [
            {
              Bodies.name = "Sam";
              invite_key = Keys.public sam_invite;
              expires_at = in_hours 72.;
              admission = None;
            };
          ];
        relays = [ a.url; b.url ];
      }
  in
  b.down <- true;
  let dinner_hash, _ = ok (Node.write c.host ~kind:"dinner" dinner) in
  ignore (Sync.sync ~transport:c.net c.host);
  b.down <- false;
  if later then begin
    let _, sg = ok (Node.write c.host ~kind:"summary" (summary "after")) in
    ignore (Fake_relay.force b sg)
  end;
  (* The host's node never syncs again. Sam joins on relay A. *)
  let sam = new_node () in
  let sd = ok (Node.init sam ~phrase:(Phrase.generate ())) in
  let sam_join =
    Envelope.create ~key:sam_invite ~seq:1 ~epoch:0 ~kind:"join"
      (Bodies.make_join ~invite_key:sam_invite ~dinner_hash
         ~identity:sd.identity
         ~device:(ok (Node.device_key sam)))
  in
  (match Relay_client.append c.net ~base:a.url ~key:None sam_join with
  | Ok _ -> ()
  | Error e -> Alcotest.fail (Relay_client.error_to_string e));
  let r = ok (Sync.sync ~transport:c.net c.roman) in
  let rb =
    List.find (fun (rr : Sync.relay_report) -> rr.relay = b.url) r.relays
  in
  (c, b, rb, dinner_hash, sd)

let replicates_dinner_ahead_of_join () =
  let c, b, rb, dinner_hash, sd = replicate_unpushed_dinner ~later:false in
  Alcotest.(check (option string)) "relay B synced" None rb.error;
  Alcotest.(check int) "the dinner and sam's join replicated" 2 rb.replicated;
  Alcotest.(check bool)
    "relay B holds the dinner" true
    (List.exists (fun (s : Fake_relay.stored) -> s.hash = dinner_hash) b.items);
  Alcotest.(check bool)
    "sam's identity admitted on relay B" true
    (Fold.find (Fake_relay.fold b) (Keys.public sd.identity) <> None);
  Alcotest.(check int)
    "no replicate_refused fault" 0
    (List.length (faults_of c.roman "replicate_refused"))

let replicated_dinner_behind_its_host_chain () =
  let c, b, rb, dinner_hash, _ = replicate_unpushed_dinner ~later:true in
  Alcotest.(check (option string)) "relay B synced" None rb.error;
  Alcotest.(check int) "nothing replicated" 0 rb.replicated;
  Alcotest.(check bool)
    "relay B lacks the dinner" false
    (List.exists (fun (s : Fake_relay.stored) -> s.hash = dinner_hash) b.items);
  let refused = faults_of c.roman "replicate_refused" in
  Alcotest.(check (list string))
    "the dinner and the join are replicate_refused faults" [ "dinner"; "join" ]
    (List.sort compare
       (List.map
          (fun (f : Log.fault) ->
            if Astring_contains.contains f.detail "the dinner " then "dinner"
            else "join")
          refused));
  Alcotest.(check bool)
    "the dinner's names sequence_regression" true
    (List.exists
       (fun (f : Log.fault) ->
         Astring_contains.contains f.detail "the dinner "
         && Astring_contains.contains f.detail "sequence_regression")
       refused);
  Alcotest.(check bool)
    "and roman still holds the dinner" true
    (Log.find c.roman.log dinner_hash <> None)

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

(* The host writes three summaries before Roman joins. Every relay withholds them from Roman, whose
   join epoch is past theirs, so Roman's node expects those seqs missing and holds no gap for them;
   the summary the host writes after the join reaches Roman, and a hole above it is still a gap. *)
let no_gap_before_join () =
  let host = new_node () and roman = new_node () in
  let hd = ok (Node.init host ~phrase:(Phrase.generate ())) in
  let rd = ok (Node.init roman ~phrase:(Phrase.generate ())) in
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
              expires_at = in_hours 72.;
              admission = None;
            };
          ];
        relays = [ "https://a.test" ];
      }
  in
  let root, _ = ok (Node.write host ~kind:"dinner" dinner) in
  Node.set_root host root;
  Node.set_root roman root;
  List.iter
    (fun i ->
      ignore (ok (Node.write host ~kind:"summary" (summary (string_of_int i)))))
    [ 1; 2; 3 ];
  let a = Fake_relay.create ~url:"https://a.test" ~root in
  let net = Fake_relay.network [ a ] in
  Log.add_relay host.log a.url;
  Log.add_relay roman.log a.url;
  ignore (ok (Sync.sync ~transport:net host));
  let join =
    Bodies.make_join ~invite_key:invite ~dinner_hash:root ~identity:rd.identity
      ~device:(ok (Node.device_key roman))
  in
  let sg = Envelope.create ~key:invite ~seq:1 ~epoch:0 ~kind:"join" join in
  (match Relay_client.append net ~base:a.url ~key:None sg with
  | Ok _ -> ()
  | Error e -> Alcotest.fail (Relay_client.error_to_string e));
  ignore (ok (Node.import roman sg));
  ignore (ok (Sync.sync ~transport:net roman));
  ignore (ok (Sync.sync ~transport:net host));
  let after, _ = ok (Node.write host ~kind:"summary" (summary "after")) in
  ignore (ok (Sync.sync ~transport:net host));
  let r = ok (Sync.sync ~transport:net roman) in
  Alcotest.(check bool)
    "the summary after the join reached Roman" true
    (Log.find roman.log after <> None);
  Alcotest.(check (list (pair string int)))
    "no gap for content written before the join" []
    (List.map
       (fun (f : Log.fault) -> (f.author, f.seq))
       (faults_of roman "gap"));
  Alcotest.(check int) "nothing raised" 0 (List.length r.raised);
  (* A hole at or past the floor is still a gap. *)
  let h1, _ = ok (Node.write host ~kind:"summary" (summary "five")) in
  let _h2, _ = ok (Node.write host ~kind:"summary" (summary "six")) in
  ignore (ok (Sync.sync ~transport:net host));
  Fake_relay.remove a h1;
  ignore (ok (Sync.sync ~transport:net roman));
  Alcotest.(check int)
    "a hole past the floor is a gap" 1
    (List.length (faults_of roman "gap"))

(* digestif device publish for Roman's mail key: signs once, resumes the pending message on a repeat,
   and refuses the key once the circle admits it. *)
let publish_mail (c : circle) =
  let key = Keys.public (ok (Node.mail_key c.roman)) in
  Node.publish_device c.roman ~key ~role:Bodies.Mail ~identity:(fun () ->
      Node.identity_from_phrase c.roman c.roman_phrase)

let device_rows (n : Node.t) =
  List.filter
    (fun (r : Log.row) -> r.signed.envelope.kind = "device")
    (Log.all n.log)

let device_publish_resumes () =
  let c = make_circle () in
  let first =
    match ok (publish_mail c) with
    | `Signed h -> h
    | `Pending _ -> Alcotest.fail "the first publish signs"
  in
  (match ok (publish_mail c) with
  | `Pending h -> check_str "a repeat resumes the pending message" first h
  | `Signed _ -> Alcotest.fail "a repeat signed a second message");
  Alcotest.(check int)
    "one device message" 1
    (List.length (device_rows c.roman));
  ignore (ok (Sync.sync ~transport:c.net c.roman));
  match publish_mail c with
  | Ok _ -> Alcotest.fail "published a key the circle admits"
  | Error e ->
      Alcotest.(check bool)
        "refused as admitted" true
        (Astring_contains.contains e "already admitted")

(* Roman's node on Nov 3: the mail key admitted, then four more device messages for it signed while
   the relay refused them, then a summary and a reply to it. The relay refuses the repeats as
   not_admitted; the next sync drops them, re-signs the summary and the reply after the last
   envelope a relay took, and pushes them, and the host folding the result sees no gap. *)
let refused_own_dropped () =
  let c = make_circle () in
  ignore (ok (publish_mail c));
  ignore (ok (Sync.sync ~transport:c.net c.roman));
  let device = Option.get (Log.get_config c.roman.log Node.k_device) in
  let mail = Option.get (Log.get_config c.roman.log Node.k_mail) in
  let admitted = Option.get (Log.max_seq c.roman.log device) in
  for _ = 1 to 4 do
    ignore
      (ok
         (Node.write c.roman ~kind:"device"
            (Bodies.make_device
               ~identity:(ok (Node.identity_from_phrase c.roman c.roman_phrase))
               ~key:mail ~role:Bodies.Mail)))
  done;
  let s1, _ = ok (Node.write c.roman ~kind:"summary" (summary "after")) in
  let reply =
    `Assoc [ ("text", `String "and more"); ("reply_to", `String s1) ]
  in
  ignore (ok (Node.write c.roman ~kind:"summary" reply));
  let r = ok (Sync.sync ~transport:c.net c.roman) in
  Alcotest.(check (list (option string)))
    "no relay reports an error" [ None; None ]
    (List.map (fun (rr : Sync.relay_report) -> rr.error) r.relays);
  Alcotest.(check int)
    "the four repeats are dropped" 4
    (List.fold_left
       (fun n (rr : Sync.relay_report) -> n + rr.dropped)
       0 r.relays);
  Alcotest.(check int)
    "one device message is left" 1
    (List.length (device_rows c.roman));
  let chain = Log.by_author c.roman.log device in
  Alcotest.(check (list int))
    "the chain runs on with no gap"
    (List.init (admitted + 2) (fun i -> i + 1))
    (List.map (fun (r : Log.row) -> r.signed.envelope.seq) chain);
  let summary_row, reply_row =
    match List.rev chain with
    | b :: a :: _ -> (a, b)
    | _ -> Alcotest.fail "no summaries"
  in
  Alcotest.(check (option string))
    "the reply names the re-signed summary" (Some summary_row.hash)
    (Log.reply_to_of reply_row.signed.body);
  List.iter
    (fun (rl : Fake_relay.t) ->
      Alcotest.(check bool)
        (rl.url ^ " holds the reply")
        true
        (List.exists
           (fun (s : Fake_relay.stored) -> s.hash = reply_row.hash)
           rl.items))
    c.relays;
  ignore (ok (Sync.sync ~transport:c.net c.host));
  Alcotest.(check (list string))
    "the host folds it with no fault" []
    (List.map (fun (f : Log.fault) -> f.kind) (Log.open_faults c.host.log));
  Alcotest.(check (list string))
    "nor does Roman" []
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

(* A relay that serves entries with no envelope in them replaces the envelope of every entry
   [bad] names, on the relay at [base], with one no envelope parses from. *)
let serving_unparsable ~base bad (net : Relay_client.transport) :
    Relay_client.transport =
 fun ~meth ~url ~headers ~body ->
  match net ~meth ~url ~headers ~body with
  | Ok ({ status = 200; body = b } as r)
    when String.starts_with ~prefix:(base ^ "/v0/envelopes") url ->
      let entry = function
        | `Assoc f when List.mem (List.assoc_opt "relay_id" f) bad ->
            `Assoc
              (List.map
                 (fun (k, v) ->
                   if k = "envelope" then (k, `Assoc [ ("version", `Int 0) ])
                   else (k, v))
                 f)
        | e -> e
      in
      let page =
        match Yojson.Safe.from_string b with
        | `Assoc f ->
            `Assoc
              (List.map
                 (function
                   | "envelopes", `List l ->
                       ("envelopes", `List (List.map entry l))
                   | kv -> kv)
                 f)
        | j -> j
      in
      Ok { r with body = Yojson.Safe.to_string page }
  | other -> other

(* An entry a relay serves that this node cannot read (a string that is not UTF-8, which has no
   canonical form and so no hash; an entry with no envelope in it) is a fault against that entry, and
   the sync reads on past it: the envelopes around it are stored and the cursor passes it. DIG-222 *)
let unreadable_entries_passed_over () =
  let c = make_circle () in
  ignore (ok (Sync.sync ~transport:c.net c.roman));
  let key = ok (Node.device_key c.host) in
  let a = relay c "https://a.test" in
  let sg =
    Envelope.create ~key ~seq:1000 ~epoch:1 ~kind:"summary"
      (summary "never served as signed")
  in
  let not_utf8 =
    {
      sg with
      envelope = { sg.envelope with created_at = "2026-11-20T00:00:00\xffZ" };
    }
  in
  ignore (Fake_relay.force a ~hash:(Some "sha256:00") not_utf8);
  let unparsable = Fake_relay.force a sg in
  let h_after, _ = ok (Node.write c.host ~kind:"summary" (summary "after")) in
  ignore (ok (Sync.sync ~transport:c.net c.host));
  let net =
    serving_unparsable ~base:a.url [ Some (`Int unparsable.relay_id) ] c.net
  in
  let report = ok (Sync.sync ~transport:net c.roman) in
  Alcotest.(check (list (option string)))
    "every relay reads clean"
    (List.map (fun _ -> None) report.relays)
    (List.map (fun (r : Sync.relay_report) -> r.error) report.relays);
  Alcotest.(check bool)
    "the envelope after them is stored" true
    (Log.find c.roman.log h_after <> None);
  Alcotest.(check int)
    "the string that is not UTF-8 is a fault" 1
    (List.length (faults_of c.roman "invalid_envelope"));
  Alcotest.(check (list int))
    "the entry with no envelope is a fault at its place" [ unparsable.relay_id ]
    (List.map
       (fun (f : Log.fault) -> f.seq)
       (faults_of c.roman "malformed_entry"));
  let cursor =
    (List.find
       (fun (r : Log.relay_row) -> r.url = a.url)
       (Log.relays c.roman.log))
      .cursor
  in
  Alcotest.(check bool) "the cursor passes both" true (cursor >= a.next_id - 1);
  let open_before = List.length (Log.open_faults c.roman.log) in
  ignore (ok (Sync.sync ~transport:net c.roman));
  Alcotest.(check int)
    "a second read raises nothing new" open_before
    (List.length (Log.open_faults c.roman.log))

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

(* An answer the mail key wrote reaches one relay only (an emailed answer link appends it there);
   the node reads it as its own and pushes it to the other relay signed by the mail key, its author,
   since a relay refuses a non-join whose request signer is not its author (DIG-149). *)
let mail_envelope_pushed_by_its_author () =
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
  let answer =
    Envelope.create ~key:mail ~seq:1 ~prev:ask ~epoch:(Node.fold c.roman).epoch
      ~kind:"answer" (summary "by mail")
  in
  (match Relay_client.append c.net ~base:a.url ~key:(Some mail) answer with
  | Ok _ -> ()
  | Error e -> Alcotest.fail (Relay_client.error_to_string e));
  let r = ok (Sync.sync ~transport:c.net c.roman) in
  let rb =
    List.find (fun (rr : Sync.relay_report) -> rr.relay = b.url) r.relays
  in
  Alcotest.(check (option string)) "relay B synced" None rb.error;
  Alcotest.(check bool)
    "relay B holds the mail key's answer" true
    (List.exists
       (fun (s : Fake_relay.stored) -> s.hash = Envelope.hash answer.envelope)
       b.items)

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

(* A signer_set is a release document (protocol.md, signer_set): the fold applies one with a
   document and a signatures list and rejects one without, as for the other release kinds. *)
let signer_set_shape () =
  let c = make_circle () in
  let good = `Assoc [ ("document", `String "e30"); ("signatures", `List []) ] in
  let bad = `Assoc [ ("signatures", `String "none") ] in
  let good_hash, _ = ok (Node.write c.host ~kind:"signer_set" good) in
  let bad_hash, _ = ok (Node.write c.host ~kind:"signer_set" bad) in
  let f = Fold.run ~root:c.root (Log.fold_entries c.host.Node.log) in
  Alcotest.(check bool)
    "a signer_set with a document and signatures folds" true
    (List.mem good_hash f.applied);
  Alcotest.(check bool)
    "one without is rejected" true
    (List.mem_assoc bad_hash f.rejected)

(* ISS-87806: a signer-set change is held to its kind against the current set (docs/releases.md,
   Changing the signer set): a promotion adds one key, a removal takes one out, a replacement swaps
   one, and no set has fewer than two keys or one twice. *)
let approval_set_change () =
  let k () = Keys.public (Crypto.generate_signing_key ()) in
  let a = k () and b = k () and c = k () and d = k () in
  let set l = List.map (fun key -> { Approval.name = "n"; key }) l in
  let doc l =
    Approval.signers_document ~created_at:"2026-11-14T15:00:00.000Z" (set l)
  in
  let check ~kind ?removed ?added current l =
    Approval.check_set_change ~kind ~current:(set current) ?removed ?added
      (doc l)
  in
  Alcotest.(check (result (option string) string))
    "a promotion adds one key, which signs first" (Ok (Some c))
    (check ~kind:Promotion [ a; b ] [ a; b; c ]);
  Alcotest.(check bool)
    "not two" true
    (Result.is_error (check ~kind:Promotion [ a; b ] [ a; b; c; d ]));
  Alcotest.(check (result (option string) string))
    "a removal takes its key out" (Ok None)
    (check ~kind:Removal ~removed:c [ a; b; c ] [ a; b ]);
  Alcotest.(check bool)
    "never below two keys" true
    (Result.is_error (check ~kind:Removal ~removed:b [ a; b ] [ a ]));
  Alcotest.(check (result (option string) string))
    "a replacement swaps one key" (Ok (Some d))
    (check ~kind:Replacement ~removed:b ~added:d [ a; b ] [ a; d ]);
  Alcotest.(check bool)
    "a key twice" true
    (Result.is_error (check ~kind:Promotion [ a; b ] [ a; b; a ]))

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

(* A held keystore reads each present key from its backend once; a put or a delete through it is what
   it answers next, and an absent key is asked again, since another process may create it. ISS-83181 *)
let keystore_held () =
  let inner = Keystore.memory () in
  let reads = ref 0 in
  let counted =
    {
      inner with
      get =
        (fun n ->
          incr reads;
          inner.get n);
    }
  in
  let ks = Keystore.held counted in
  Alcotest.(check (option string)) "absent" None (ok (ks.get "device"));
  Alcotest.(check (option string)) "absent again" None (ok (ks.get "device"));
  Alcotest.(check int) "an absent key is asked each time" 2 !reads;
  ok (inner.put "device" "from another process");
  Alcotest.(check (option string))
    "found once another process created it" (Some "from another process")
    (ok (ks.get "device"));
  ignore (ok (ks.get "device"));
  ignore (ok (ks.get "device"));
  Alcotest.(check int) "a present key is read once" 3 !reads;
  ok (ks.put "device" "rotated");
  Alcotest.(check (option string))
    "a put is held" (Some "rotated")
    (ok (ks.get "device"));
  Alcotest.(check int) "without a read" 3 !reads;
  ok (ks.delete "device");
  Alcotest.(check (option string))
    "a delete is not held" None
    (ok (ks.get "device"));
  Alcotest.(check int) "so it reads again" 4 !reads

let service_files () =
  let standard = Node.standard_dir () in
  let plist =
    Service.launchd_plist ~exe:"/usr/local/bin/digestif" ~dir:standard
      ~log_dir:"/tmp/x" ~path:"/opt/homebrew/bin:/usr/bin:/bin" ()
  in
  Alcotest.(check bool)
    "plist runs the node" true
    (List.for_all
       (fun s -> Astring_contains.contains plist s)
       [
         "<string>com.digestif.node</string>";
         "<string>run</string>";
         "<string>" ^ Service.xml_escape standard ^ "</string>";
         "<key>PATH</key>\n    <string>/opt/homebrew/bin:/usr/bin:/bin</string>";
       ]);
  let unit =
    Service.systemd_unit ~exe:"/usr/bin/digestif"
      ~dir:"/home/x/.local/share/digestif" ~path:"/home/x/my bin:/usr/bin:/a%b"
      ()
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

(* Runs [f] with HOME, XDG_DATA_HOME and XDG_CONFIG_HOME under a fresh directory, restoring them
   after. *)
let with_temp_home f =
  let keys = [ "HOME"; "XDG_DATA_HOME"; "XDG_CONFIG_HOME"; "DIGESTIF_HOME" ] in
  let saved = List.map (fun k -> (k, Sys.getenv_opt k)) keys in
  let home = Filename.temp_dir "digestif-home" "" in
  Unix.putenv "HOME" home;
  Unix.putenv "XDG_DATA_HOME" (Filename.concat home ".local/share");
  Unix.putenv "XDG_CONFIG_HOME" (Filename.concat home ".config");
  Unix.putenv "DIGESTIF_HOME" "";
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun (k, v) -> Unix.putenv k (Option.value v ~default:"")) saved)
    (fun () -> f home)

(* A second node on the machine gets a service, a unit and a UI port of its own, derived from its
   data directory; the standard node keeps the fixed ones. DIG-264 *)
let service_per_data_directory () =
  with_temp_home @@ fun home ->
  let standard = Node.standard_dir () in
  let second = Filename.concat home "circles/Second Circle" in
  Node.mkdir_p second;
  check_str "the standard node's label" "com.digestif.node"
    (Service.label_of standard);
  check_str "the standard node's unit" "digestif.service"
    (Service.unit_name_of standard);
  Alcotest.(check int)
    "the standard node's port" 7420 (Service.ui_port standard);
  let label = Service.label_of second in
  let prefix = "com.digestif.node.second-circle-" in
  Alcotest.(check bool)
    ("a second node's label: " ^ label)
    true
    (String.length label = String.length prefix + 8
    && String.sub label 0 (String.length prefix) = prefix);
  check_str "its unit carries the same slug"
    ("digestif-" ^ String.sub label 18 (String.length label - 18) ^ ".service")
    (Service.unit_name_of second);
  let port = Service.ui_port second in
  Alcotest.(check bool) "its port is its own" true (port > 7420 && port < 8000);
  Alcotest.(check int)
    "the same directory, spelled with a trailing slash, is the same node" port
    (Service.ui_port (second ^ "/"));
  let other = Filename.concat home "elsewhere/Second Circle" in
  Node.mkdir_p other;
  Alcotest.(check bool)
    "one base name in two places is two services" true
    (Service.label_of other <> label);
  let plan dir = Service.plan ~exe:"/x/digestif" ~dir ~path:"/bin" () in
  Alcotest.(check bool)
    "the two plans write different files" true
    ((plan standard).path <> (plan second).path);
  Alcotest.(check (list string)) "nothing to retire" [] (plan second).retire;
  (* A fixed-name file that runs this directory was this node's, installed before the names were
     derived: the install retires it. One that runs the standard node stays. *)
  let fixed = (plan standard).path in
  Node.mkdir_p (Filename.dirname fixed);
  let write_fixed dir =
    Out_channel.with_open_bin fixed (fun oc ->
        output_string oc (plan dir).contents)
  in
  write_fixed standard;
  Alcotest.(check (list string))
    "the standard node's service stays" [] (plan second).retire;
  write_fixed second;
  Alcotest.(check (list string))
    "this node's fixed-name service is retired" [ fixed ] (plan second).retire;
  Alcotest.(check int)
    "and unloaded beside its own" 2
    (List.length (plan second).unload)

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

(* One log, many processes: the daemon, its per-request connections, the behaviors and every CLI call
   each open it. Each child opens the log, writes one config row and closes it, and its exit code
   says whether any of that raised. ISS-47731 *)
let log_writer_flag = "--log-writer"

let log_writer path i =
  try
    let t = Log.open_ path in
    Log.set_config t (Printf.sprintf "writer-%s" i) "done";
    Log.close t;
    exit 0
  with e ->
    prerr_endline (Printexc.to_string e);
    exit 1

(* Each writer is this test binary run again, so it is a process of its own and shares nothing of
   SQLite's in-process state with the test. *)
let spawn_writers path n =
  List.init n (fun i ->
      Unix.create_process Sys.executable_name
        [| Sys.executable_name; log_writer_flag; path; string_of_int i |]
        Unix.stdin Unix.stdout Unix.stderr)

let wait_writers pids =
  List.map
    (fun pid ->
      match Unix.waitpid [] pid with _, Unix.WEXITED c -> c | _ -> -1)
    pids

let check_writers path n codes =
  Alcotest.(check (list int))
    "every process opened and wrote"
    (List.init n (fun _ -> 0))
    codes;
  let t = Log.open_ path in
  let written =
    List.filter
      (fun i -> Log.get_config t (Printf.sprintf "writer-%d" i) = Some "done")
      (List.init n Fun.id)
  in
  Log.close t;
  Alcotest.(check int) "every write landed" n (List.length written)

let fresh_log_path () =
  let dir = tmpdir () in
  Node.mkdir_p dir;
  Filename.concat dir "log.sqlite3"

(* A connection reopened on a log this process opened answers its reads and writes without the
   schema work. ISS-83181 *)
let log_reopen () =
  let path = fresh_log_path () in
  let t = Log.open_ path in
  Log.set_config t "k" "v";
  let r = Log.reopen path in
  check_str "reads" "v" (Option.get (Log.get_config r "k"));
  Log.set_config r "k2" "v2";
  Log.close r;
  check_str "writes" "v2" (Option.get (Log.get_config t "k2"));
  Log.close t

(* Processes that create the same new log at once all open it: the schema, WAL and migrations are
   raced, and each waits for the others' locks rather than answering BUSY. *)
let log_created_by_many_processes () =
  let path = fresh_log_path () in
  check_writers path 8 (wait_writers (spawn_writers path 8))

(* A process opening the log while another connection holds the write lock waits for it. The lock
   is held for a second: inside the busy timeout, and long past an open with no busy handler. *)
let log_opened_while_another_writes () =
  let path = fresh_log_path () in
  let holder = Log.open_ path in
  let pids =
    Log.transaction holder (fun () ->
        Log.set_config holder "holder" "writing";
        let pids = spawn_writers path 4 in
        Unix.sleepf 1.0;
        pids)
  in
  Log.close holder;
  check_writers path 4 (wait_writers pids)

(* A transaction opened inside another is part of it: its write commits with the outer one, and one
   that raises rolls back only what it wrote. The daily digest's transaction reaches store writes
   that hold their own. *)
let log_transaction_nests () =
  let t = Log.open_ (fresh_log_path ()) in
  Log.transaction t (fun () ->
      Log.set_config t "outer" "1";
      Log.transaction t (fun () -> Log.set_config t "inner" "1");
      (try
         Log.transaction t (fun () ->
             Log.set_config t "failed" "1";
             failwith "inner")
       with Failure _ -> ());
      Log.transaction t (fun () ->
          Log.transaction t (fun () -> Log.set_config t "deeper" "1")));
  Alcotest.(check (list (option string)))
    "committed together; the failed one rolled back alone"
    [ Some "1"; Some "1"; None; Some "1" ]
    (List.map (Log.get_config t) [ "outer"; "inner"; "failed"; "deeper" ]);
  Log.transaction t (fun () -> Log.set_config t "after" "1");
  Alcotest.(check (option string))
    "a transaction after them opens again" (Some "1") (Log.get_config t "after");
  Log.close t

(* One connection, several threads at once: the daemon's UI thread and its main thread each reach a
   log, and the binding lets them run inside SQLite together. Each thread writes and reads its own
   rows; the process's exit says whether the connection survived it, since a connection corrupted by
   two threads at once dies of SIGSEGV or spins rather than raising. ISS-79885 *)
let log_threads_flag = "--log-threads"

let log_threads path =
  try
    let t = Log.open_ path in
    let failed = Atomic.make false in
    let work i () =
      try
        for j = 1 to 300 do
          let key = Printf.sprintf "thread-%d-%d" i j in
          Log.set_config t key "done";
          if Log.get_config t key <> Some "done" then Atomic.set failed true
        done
      with e ->
        prerr_endline (Printexc.to_string e);
        Atomic.set failed true
    in
    List.iter Thread.join (List.init 4 (fun i -> Thread.create (work i) ()));
    Log.close t;
    exit (if Atomic.get failed then 1 else 0)
  with e ->
    prerr_endline (Printexc.to_string e);
    exit 1

let log_one_connection_many_threads () =
  let path = fresh_log_path () in
  let pid =
    Unix.create_process Sys.executable_name
      [| Sys.executable_name; log_threads_flag; path |]
      Unix.stdin Unix.stdout Unix.stderr
  in
  let status =
    match Unix.waitpid [] pid with
    | _, Unix.WEXITED c -> Printf.sprintf "exit %d" c
    | _, Unix.WSIGNALED s -> Printf.sprintf "signal %d" s
    | _, Unix.WSTOPPED s -> Printf.sprintf "stopped %d" s
  in
  Alcotest.(check string) "the threads shared the connection" "exit 0" status

(* DIG-229: one node, many processes signing at once (the daemon, a CLI write beside it). Each child
   opens the node's data directory with the keystore on disk and signs [own_signers_writes]
   summaries; its exit code says whether any write failed. *)
let own_signer_flag = "--own-signer"
let own_signers_writes = 10

let own_signer dir i =
  try
    let n = Node.open_ ~keystore:(Keystore.insecure_dir dir) dir in
    for w = 1 to own_signers_writes do
      ignore
        (ok
           (Node.write n ~kind:"summary"
              (`Assoc [ ("text", `String (Printf.sprintf "%s/%d" i w)) ])))
    done;
    Node.close n;
    exit 0
  with e ->
    prerr_endline (Printexc.to_string e);
    exit 1

let own_chain_many_processes () =
  let dir = tmpdir () in
  let n = Node.open_ ~keystore:(Keystore.insecure_dir dir) dir in
  ignore (ok (Node.init n ~phrase:(Phrase.generate ())));
  let author = Keys.public (ok (Node.device_key n)) in
  let processes = 6 in
  let pids =
    List.init processes (fun i ->
        Unix.create_process Sys.executable_name
          [| Sys.executable_name; own_signer_flag; dir; string_of_int i |]
          Unix.stdin Unix.stdout Unix.stderr)
  in
  Alcotest.(check (list int))
    "every process signed every envelope"
    (List.init processes (fun _ -> 0))
    (wait_writers pids);
  let chain = Log.by_author n.log author in
  let total = processes * own_signers_writes in
  Alcotest.(check (list int))
    "one envelope at each seq, no gap"
    (List.init total (fun i -> i + 1))
    (List.map (fun (r : Log.row) -> r.signed.envelope.seq) chain);
  let _ =
    List.fold_left
      (fun prev (r : Log.row) ->
        Alcotest.(check (option string))
          (Printf.sprintf "seq %d names the one before it" r.signed.envelope.seq)
          prev r.signed.envelope.prev;
        Some r.hash)
      None chain
  in
  Node.close n

(* The log itself refuses a second envelope this node signed at a seq it already signed, so a writer
   that read its position outside [Node.write] cannot fork the chain either. DIG-229 *)
let own_seq_unique () =
  let dir = tmpdir () in
  let n = Node.open_ ~keystore:(Keystore.memory ()) dir in
  ignore (ok (Node.init n ~phrase:(Phrase.generate ())));
  let key = ok (Node.device_key n) in
  let _, first = ok (Node.write n ~kind:"summary" (summary "first")) in
  let second =
    Envelope.create ~key ~seq:first.envelope.seq ~epoch:first.envelope.epoch
      ~kind:"summary"
      (summary "a second at the same seq")
  in
  Alcotest.(check bool)
    "a second own envelope at one seq is refused" true
    (match Node.store n second with _ -> false | exception Failure _ -> true);
  (* What another writer signed at that seq is still kept: a fork is a fact the fold surfaces. *)
  ignore (ok (Node.import n second));
  Alcotest.(check int)
    "a fork read from elsewhere is kept beside it" 2
    (List.length
       (Log.by_author_seq n.log ~author:(Keys.public key)
          ~seq:first.envelope.seq));
  Node.close n

let () =
  match Sys.argv with
  | [| _; flag; path; i |] when flag = log_writer_flag -> log_writer path i
  | [| _; flag; dir; i |] when flag = own_signer_flag -> own_signer dir i
  | [| _; flag; path |] when flag = log_threads_flag -> log_threads path
  | _ -> ()

(* DIG-378: a run in its own process group is killed with what it spawned at the deadline, and a
   program that cannot be started in a group reads as exit 127. *)
let proc_group_kills_children () =
  let pid_file = Filename.temp_file "proc-group" ".pid" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove pid_file with Sys_error _ -> ())
    (fun () ->
      (match
         Proc.run ~group:true ~timeout:1.
           [|
             "sh";
             "-c";
             Printf.sprintf "sleep 30 & echo $! > %s; wait"
               (Filename.quote pid_file);
           |]
       with
      | Ok _ -> Alcotest.fail "the run should have passed its deadline"
      | Error _ -> ());
      let child =
        match
          int_of_string_opt
            (String.trim
               (In_channel.with_open_bin pid_file In_channel.input_all))
        with
        | Some c -> c
        | None -> Alcotest.fail "the background sleep never wrote its pid"
      in
      (* The kill lands before the run returns, but the process may take a moment to be reaped. *)
      let rec gone tries =
        match Unix.kill child 0 with
        | exception Unix.Unix_error (Unix.ESRCH, _, _) -> true
        | () when tries > 0 ->
            Unix.sleepf 0.05;
            gone (tries - 1)
        | () -> false
      in
      let is_gone = gone 60 in
      (* Do not leave a sleep behind when the kill failed. *)
      (if not is_gone then try Unix.kill child Sys.sigkill with _ -> ());
      Alcotest.(check bool) "the background sleep is gone" true is_gone)

let proc_group_missing_program () =
  match Proc.run ~group:true [| "/nonexistent/digestif-no-such-program" |] with
  | Ok r -> Alcotest.(check int) "exit 127" 127 r.Proc.code
  | Error e -> Alcotest.failf "unexpected error: %s" e

let () =
  Ci_alcotest.run "digestif-core"
    [
      ( "jcs",
        [
          Alcotest.test_case "numbers" `Quick jcs_numbers;
          Alcotest.test_case "RFC example" `Quick jcs_rfc_example;
          Alcotest.test_case "sorting" `Quick jcs_sorting;
          Alcotest.test_case "rejects" `Quick jcs_rejects;
        ] );
      ("encoding", [ Alcotest.test_case "base64url" `Quick b64 ]);
      ( "log",
        [
          Alcotest.test_case "created by many processes at once" `Quick
            log_created_by_many_processes;
          Alcotest.test_case "opened while another connection writes" `Quick
            log_opened_while_another_writes;
          Alcotest.test_case "a transaction nests" `Quick log_transaction_nests;
          Alcotest.test_case "own chain signed by many processes" `Quick
            own_chain_many_processes;
          Alcotest.test_case "an own seq is signed once" `Quick own_seq_unique;
          Alcotest.test_case "one connection, many threads" `Quick
            log_one_connection_many_threads;
        ] );
      ( "proc",
        [
          Alcotest.test_case "a group kill takes the children" `Quick
            proc_group_kills_children;
          Alcotest.test_case "a missing program in a group is exit 127" `Quick
            proc_group_missing_program;
        ] );
      ( "time",
        [
          Alcotest.test_case "the Z form" `Quick z_form;
          Alcotest.test_case "date time with offset" `Quick
            date_time_with_offset;
        ] );
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
          Alcotest.test_case "an admitted node replicates joins" `Quick
            admitted_node_replicates_joins;
          Alcotest.test_case "replication runs after every relay is read" `Quick
            replicates_whatever_the_relay_order;
          Alcotest.test_case "a dinner is replicated ahead of its join" `Quick
            replicates_dinner_ahead_of_join;
          Alcotest.test_case "a replicated dinner behind its host's chain"
            `Quick replicated_dinner_behind_its_host_chain;
          Alcotest.test_case "unknown and expired invites" `Quick
            unknown_spent_expired_invites;
          Alcotest.test_case "divergent histories merge" `Quick
            divergent_histories_merge;
          Alcotest.test_case "gap backfill" `Quick gap_backfill;
          Alcotest.test_case "no gap before the join" `Quick no_gap_before_join;
          Alcotest.test_case "fork surfaced" `Quick fork_surfaced;
          Alcotest.test_case "device publish resumes, refuses admitted" `Quick
            device_publish_resumes;
          Alcotest.test_case "a refused own envelope is dropped" `Quick
            refused_own_dropped;
          Alcotest.test_case "duplicates idempotent" `Quick
            duplicates_idempotent;
          Alcotest.test_case "unreadable entries are passed over" `Quick
            unreadable_entries_passed_over;
          Alcotest.test_case "revocation" `Quick revocation;
          Alcotest.test_case "mail key revocation" `Quick mail_revocation;
          Alcotest.test_case "mail envelope pushed by its author" `Quick
            mail_envelope_pushed_by_its_author;
          Alcotest.test_case "revoke shape" `Quick revoke_shape;
          Alcotest.test_case "signer_set shape" `Quick signer_set_shape;
          Alcotest.test_case "approval set change" `Quick approval_set_change;
          Alcotest.test_case "revoke cutoffs" `Quick revoke_cutoffs;
          Alcotest.test_case "host device revokes a joiner" `Quick
            host_device_revokes_joiner;
          Alcotest.test_case "retract" `Quick retract;
          Alcotest.test_case "epoch floor" `Quick epoch_floor;
        ] );
      ( "platform",
        [
          Alcotest.test_case "file keystore" `Quick keystore_file;
          Alcotest.test_case "held keystore" `Quick keystore_held;
          Alcotest.test_case "a reopened log" `Quick log_reopen;
          Alcotest.test_case "service files" `Quick service_files;
          Alcotest.test_case "service per data directory" `Quick
            service_per_data_directory;
          Alcotest.test_case "service waits for unload" `Quick
            service_waits_for_unload;
        ] );
    ]
