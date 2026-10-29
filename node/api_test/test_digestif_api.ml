(* The generated relay types decode what the relay serves and encode what a node appends. *)

open Com_bryzek_digestif_relay

let envelope_json =
  {|{"version":0,"author":"ed25519:AAAA","seq":3,"prev":"sha256:00ff","created_at":"2026-10-29T03:00:00Z","epoch":1,"kind":"summary","body_hash":"sha256:11ee","signature":"c2ln"}|}

let page_json =
  Printf.sprintf
    {|{"envelopes":[{"relay_id":42,"hash":"sha256:22dd","envelope":%s,"body":{"text":"hi"},"received_at":"2026-10-29T03:00:01Z"}],"next":42}|}
    envelope_json

let decode of_yojson s =
  match of_yojson (Yojson.Safe.from_string s) with
  | Ok v -> v
  | Error e -> Alcotest.failf "decode failed: %s" e

let test_page () =
  let page = decode Envelope_page.of_yojson page_json in
  Alcotest.(check (option int)) "next" (Some 42) page.next;
  match page.envelopes with
  | [ stored ] ->
      Alcotest.(check int) "relay_id" 42 stored.relay_id;
      Alcotest.(check int) "seq" 3 stored.envelope.seq;
      Alcotest.(check string)
        "kind" "summary"
        (Kind.to_string stored.envelope.kind)
  | _ -> Alcotest.fail "expected one envelope"

let test_round_trip () =
  let signed =
    {
      Signed_envelope.envelope = decode Envelope.of_yojson envelope_json;
      body = Some (`Assoc [ ("text", `String "hi") ]);
    }
  in
  let again =
    decode Signed_envelope.of_yojson
      (Yojson.Safe.to_string (Signed_envelope.to_yojson signed))
  in
  Alcotest.(check bool) "round trip" true (again = signed)

let test_missing_field () =
  match Envelope.of_yojson (`Assoc [ ("version", `Int 0) ]) with
  | Ok _ -> Alcotest.fail "decoded an envelope with no author"
  | Error _ -> ()

let () =
  Alcotest.run "digestif_api"
    [
      ( "relay",
        [
          Alcotest.test_case "envelope page" `Quick test_page;
          Alcotest.test_case "signed envelope round trip" `Quick test_round_trip;
          Alcotest.test_case "missing field" `Quick test_missing_field;
        ] );
    ]
