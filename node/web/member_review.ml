(* Member review (docs/protocol.md, Member review; docs/design.md, Member review): the rules every
   node reads the same way, with nothing on the wire that opens a review. A member is silent after
   three whole UTC days in a row with no note, counted from the latest of their newest note's day,
   their newest honoured Keep's day and their join's day; the review opens at the start of the
   fourth silent UTC day. Note time is local to each member's node and never sent to the circle, so
   UTC days are the only days every node counts alike.

   A Keep is one admin's signed answer that a member stays: the plaintext
   { member, created_at, by, signature }, sealed to every admin and the member, its id the hash of
   its plaintext so a forwarded copy is the same Keep. Nothing here touches the log or the store. *)

open Digestif_core

let day = 86_400.0

(* The UTC day [t] falls on, as a day number. *)
let day_of t = Float.to_int (Float.floor (t /. day))

(* Whole UTC days in a row with no note before a member is silent. *)
let silent_days = 3

(* The moment the review opens: the start of the fourth silent UTC day after [anchor]'s. A note on
   Friday, then Saturday and Sunday, is two days; a note on Monday ends nothing, since none began. *)
let opens_at ~anchor = Float.of_int (day_of anchor + silent_days + 1) *. day

(* The latest of the newest note, the newest honoured Keep and the join: what the count runs from. *)
let anchor ~note ~keep ~join =
  List.fold_left
    (fun acc t ->
      match (acc, t) with
      | Some a, Some b -> Some (Float.max a b)
      | None, x | x, None -> x)
    None [ note; keep; join ]

let in_review ~now ~anchor = now >= opens_at ~anchor

(* Whole UTC days that have passed with no note since [anchor]'s day: the count an admin's item
   names, which is the count from Last note, or from the newest Keep when that is later. *)
let days_without ~now ~anchor = max 0 (day_of now - day_of anchor - 1)

(* ---- Keep ---- *)

type keep = {
  member : string;  (** identity of the member kept *)
  created_at : string;
  by : string;  (** the keeping admin's device key *)
  signature : string;  (** base64url, by over JCS({member, created_at, by}) *)
}

let signed_part ~member ~created_at ~by : Yojson.Safe.t =
  `Assoc
    [
      ("member", `String member);
      ("created_at", `String created_at);
      ("by", `String by);
    ]

let to_json k : Yojson.Safe.t =
  `Assoc
    [
      ("member", `String k.member);
      ("created_at", `String k.created_at);
      ("by", `String k.by);
      ("signature", `String k.signature);
    ]

(* The Keep's id: sha256 of its plaintext's canonical bytes, never the envelope's hash. *)
let id k = Keys.hash_of_bytes (Jcs.encode (to_json k))

(* A Keep of [member] signed by [device] at [created_at]. *)
let make ~(device : Crypto.signing_key) ~member ~created_at =
  let by = Keys.public device in
  let msg = Jcs.encode (signed_part ~member ~created_at ~by) in
  { member; created_at; by; signature = B64url.encode (Crypto.sign device msg) }

(* Whether [k.signature] is [k.by]'s over its signed part. Who [by] belongs to, and whether that
   identity was an admin, is the caller's to judge from the fold. *)
let verifies k =
  match (Keys.decode_ed25519 k.by, B64url.decode k.signature) with
  | Ok pub, Ok signature -> (
      match
        Jcs.encode_result
          (signed_part ~member:k.member ~created_at:k.created_at ~by:k.by)
      with
      | Ok msg -> Crypto.verify ~pub ~signature msg
      | Error _ -> false)
  | _ -> false

(* A Keep's plaintext, as an opened sealed body carries it. A plaintext missing a field, or with a
   created_at that is not a time, is no Keep. *)
let of_json (j : Yojson.Safe.t) =
  let field name =
    match j with
    | `Assoc f -> (
        match List.assoc_opt name f with
        | Some (`String s) -> Some s
        | _ -> None)
    | _ -> None
  in
  match (field "member", field "created_at", field "by", field "signature") with
  | Some member, Some created_at, Some by, Some signature
    when Time_fmt.to_unix created_at <> None ->
      Some { member; created_at; by; signature }
  | _ -> None

(* A Keep still in force: its review has not opened again (younger than three whole UTC days past
   its own day) and the member has sent no note since it. *)
let in_force ~now ~kept_at ~note =
  now < opens_at ~anchor:kept_at
  && match note with Some n -> n <= kept_at | None -> true
