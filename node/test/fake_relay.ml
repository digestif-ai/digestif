(* An in-process relay for the node's tests: the spec's three routes behind a Relay_client.transport,
   enforcing request signing, the admission fold, duplicates, forks, sequence regression and epochs.
   Not the conformance suite's relay; just enough of one to drive the node. *)

open Digestif_core

type stored = {
  relay_id : int;
  hash : string;
  signed : Envelope.signed;
  received_at : string;
}

type t = {
  url : string;
  root : string;
  mutable items : stored list;  (** newest first *)
  mutable next_id : int;
  nonces : (string * string, unit) Hashtbl.t;
  mutable down : bool;
  mutable mailer : bool;
  mutable mailed : (string * Yojson.Safe.t) list;
      (** digest hash and mail request, newest first: what a mailing relay was asked to send *)
}

let create ~url ~root =
  {
    url;
    root;
    items = [];
    next_id = 1;
    nonces = Hashtbl.create 16;
    down = false;
    mailer = false;
    mailed = [];
  }

let entries t =
  List.rev_map
    (fun s ->
      { Fold.hash = s.hash; envelope = s.signed.envelope; body = s.signed.body })
    t.items

let fold t = Fold.run ~root:t.root (entries t)

(* Store without any check: how a test makes a relay lose, hold or invent something. *)
let force t ?(hash = None) (sg : Envelope.signed) =
  let hash =
    match hash with Some h -> h | None -> Envelope.hash sg.envelope
  in
  let s =
    { relay_id = t.next_id; hash; signed = sg; received_at = Time_fmt.now () }
  in
  t.next_id <- t.next_id + 1;
  t.items <- s :: t.items;
  s

let remove t hash = t.items <- List.filter (fun s -> s.hash <> hash) t.items

let err status code =
  Ok
    {
      Relay_client.status;
      body = Printf.sprintf {|[{"code":%S,"message":%S}]|} code code;
    }

let append t ~signer (sg : Envelope.signed) =
  let e = sg.envelope in
  let hash = Envelope.hash e in
  match List.find_opt (fun s -> s.hash = hash) t.items with
  | Some s ->
      Ok
        {
          Relay_client.status = 200;
          body =
            Printf.sprintf {|{"status":"duplicate","relay_id":%d,"hash":%S}|}
              s.relay_id hash;
        }
  | None -> (
      match Envelope.verify sg with
      | Error (Envelope.Malformed _) -> err 422 "malformed"
      | Error (Envelope.Bad_signature _) -> err 422 "bad_signature"
      | Ok () ->
          let f = fold t in
          let bootstrap = e.kind = "dinner" || e.kind = "join" in
          let author_ok =
            match Fold.find f e.author with
            | Some { role = Device | Mail; revoked_by = None; _ } -> true
            | _ -> false
          in
          let signer_ok =
            match signer with Some k -> k = e.author | None -> bootstrap
          in
          let chainless = Fold.is_chainless f e.author in
          let same_seq =
            List.filter
              (fun s ->
                s.signed.envelope.author = e.author
                && s.signed.envelope.seq = e.seq)
              t.items
          in
          let last =
            List.fold_left
              (fun m s ->
                if s.signed.envelope.author = e.author then
                  max m s.signed.envelope.seq
                else m)
              0 t.items
          in
          if not signer_ok then err 401 "not_admitted"
          else if same_seq <> [] then err 422 "fork"
          else if (not chainless) && e.seq <= last then
            err 422 "sequence_regression"
          else
            let candidate = force t sg in
            let applied =
              if bootstrap || e.kind = "device" then
                List.mem hash (fold t).applied || hash = t.root
              else author_ok
            in
            if not applied then begin
              remove t hash;
              t.next_id <- t.next_id - 1;
              err 422 "not_admitted"
            end
            else
              Ok
                {
                  Relay_client.status = 201;
                  body =
                    Printf.sprintf
                      {|{"status":"accepted","relay_id":%d,"hash":%S}|}
                      candidate.relay_id hash;
                })

let stored_json s : Yojson.Safe.t =
  `Assoc
    ([
       ("relay_id", `Int s.relay_id);
       ("hash", `String s.hash);
       ("envelope", Envelope.to_json s.signed.envelope);
     ]
    @ (match s.signed.body with Some b -> [ ("body", b) ] | None -> [])
    @ [ ("received_at", `String s.received_at) ])

let page t ~reader ~after ~limit =
  let f = fold t in
  match Fold.find f reader with
  | None -> err 401 "not_admitted"
  | Some k ->
      let visible =
        List.filter
          (fun s ->
            s.relay_id > after
            && (Envelope.is_circle_state s.signed.envelope.kind
               || s.signed.envelope.epoch >= k.join_epoch))
          (List.rev t.items)
      in
      let page = List.filteri (fun i _ -> i < limit) visible in
      let next =
        if List.length visible > limit then
          match List.rev page with s :: _ -> Some s.relay_id | [] -> None
        else None
      in
      Ok
        {
          Relay_client.status = 200;
          body =
            Yojson.Safe.to_string
              (`Assoc
                 ([ ("envelopes", `List (List.map stored_json page)) ]
                 @ match next with Some n -> [ ("next", `Int n) ] | None -> []));
        }

(* POST /v0/mail: the digest must be held and written by the signer's identity; a repeat mails
   nothing. *)
let mail t ~signer raw =
  match (signer, Yojson.Safe.from_string raw) with
  | None, _ -> err 401 "not_admitted"
  | Some key, (`Assoc f as request) -> (
      let receipt status digest =
        Ok
          {
            Relay_client.status = (if status = "sent" then 202 else 200);
            body = Printf.sprintf {|{"status":%S,"digest":%S}|} status digest;
          }
      in
      match List.assoc_opt "digest" f with
      | Some (`String digest) -> (
          let fold = fold t in
          match List.find_opt (fun s -> s.hash = digest) t.items with
          | _ when not t.mailer -> err 422 "not_mailer"
          | None -> err 404 "unknown_digest"
          | Some s
            when Fold.identity_of fold s.signed.envelope.author
                 <> Fold.identity_of fold key ->
              err 401 "not_admitted"
          | Some _ ->
              if List.mem_assoc digest t.mailed then receipt "already_sent" digest
              else begin
                t.mailed <- (digest, request) :: t.mailed;
                receipt "sent" digest
              end)
      | _ -> err 422 "malformed")
  | _ -> err 422 "malformed"
  | exception Yojson.Json_error _ -> err 422 "malformed"

let query_int q name default =
  match
    List.find_map
      (fun kv ->
        match String.split_on_char '=' kv with
        | [ k; v ] when k = name -> int_of_string_opt v
        | _ -> None)
      q
  with
  | Some v -> v
  | None -> default

let transport t : Relay_client.transport =
 fun ~meth ~url ~headers ~body ->
  if t.down then Error "connection refused"
  else
    let path =
      String.sub url (String.length t.url)
        (String.length url - String.length t.url)
    in
    let raw = Option.value body ~default:"" in
    let signer =
      if List.mem_assoc "Digestif-Key" headers then
        match
          Request_sign.verify ~skew_seconds:3600 ~now:(Unix.gettimeofday ())
            ~seen:(fun ~key ~nonce ->
              let seen = Hashtbl.mem t.nonces (key, nonce) in
              Hashtbl.replace t.nonces (key, nonce) ();
              seen)
            ~meth ~path ~body:raw headers
        with
        | Ok key -> Ok (Some key)
        | Error Request_sign.Bad_signature -> Error "bad_signature"
        | Error Stale_request -> Error "stale_request"
        | Error Replayed_nonce -> Error "replayed_nonce"
      else Ok None
    in
    match (signer, meth) with
    | Error code, _ -> err 401 code
    | Ok signer, "POST" when path = "/v0/mail" -> mail t ~signer raw
    | Ok signer, "POST" -> (
        match Envelope.signed_of_json (Yojson.Safe.from_string raw) with
        | Ok sg -> append t ~signer sg
        | Error _ -> err 422 "malformed")
    | Ok None, _ -> err 401 "not_admitted"
    | Ok (Some reader), _ -> (
        match String.split_on_char '?' path with
        | [ "/v0/envelopes"; q ] ->
            let q = String.split_on_char '&' q in
            page t ~reader ~after:(query_int q "after" 0)
              ~limit:(query_int q "limit" 500)
        | _ -> err 404 "not_found")

(* Route a request to whichever fake relay owns the URL. *)
let network relays : Relay_client.transport =
 fun ~meth ~url ~headers ~body ->
  match
    List.find_opt (fun r -> String.starts_with ~prefix:r.url url) relays
  with
  | Some r -> transport r ~meth ~url ~headers ~body
  | None -> Error ("no route to " ^ url)
