(* Content bodies (protocol.md, Content bodies). A summary is plaintext; a question, answer or
   proposal names its recipient in the clear and seals its words to the recipient's card key and the
   author's own, so the author's devices can read what they sent after a rebuild from the relays.

     summary:   { "text": "...", "voice": "agent", "reply_to": "sha256:..." }
     directed:  { "to": "ed25519:<identity>", "reply_to": "sha256:...",
                  "sealed": <sealed { "text": "...", "voice": "person" }> } *)

open Digestif_core

let directed_kinds = [ "question"; "answer"; "proposal" ]
let feed_kinds = "summary" :: directed_kinds
let voices = [ "person"; "agent" ]
let get name = function `Assoc f -> List.assoc_opt name f | _ -> None

let str_field name j =
  match get name j with Some (`String s) -> Some s | _ -> None

let opt_pair name = function Some v -> [ (name, `String v) ] | None -> []

let words ~text ~voice =
  `Assoc [ ("text", `String text); ("voice", `String voice) ]

let summary_body ~text ~voice ?reply_to ?stage () : Yojson.Safe.t =
  `Assoc
    ([ ("text", `String text); ("voice", `String voice) ]
    @ opt_pair "reply_to" reply_to
    @ opt_pair "stage" stage)

(* A status note (protocol.md, Content bodies): fixed words, carried as their name and never as
   text, so a reader renders them and nothing from the record can ride along. *)
let statuses =
  [ "paused"; "waiting_for_approval"; "could_not_run"; "nothing_to_share" ]

let status_body ~status ~stage : Yojson.Safe.t =
  if not (List.mem status statuses) then invalid_arg ("status: " ^ status);
  `Assoc
    [
      ("status", `String status);
      ("voice", `String "agent");
      ("stage", `String stage);
    ]

(* A summary body's status note, when it is one this node knows. *)
let status_of (body : Yojson.Safe.t option) =
  match Option.bind body (str_field "status") with
  | Some s when List.mem s statuses -> Some s
  | _ -> None

(* The author's stage a summary carries: a missing or unknown one reads as active. *)
let stage_of (body : Yojson.Safe.t option) =
  match Option.bind body (str_field "stage") with
  | Some (("onboarding" | "active" | "paused") as s) -> s
  | _ -> "active"

let raw_x25519 k = Result.to_option (Keys.decode_x25519 k)

(* [to_key] and [self_key] are card encryption keys, x25519:<base64url>. *)
let directed_body ~to_identity ~to_key ~self_key ~text ~voice ?reply_to () =
  match (raw_x25519 to_key, raw_x25519 self_key) with
  | Some r, Some s ->
      Ok
        (`Assoc
           ([ ("to", `String to_identity) ]
           @ opt_pair "reply_to" reply_to
           @ [
               ( "sealed",
                 Digestif_mail.Seal.seal ~recipients:[ r; s ]
                   (words ~text ~voice) );
             ]))
  | _ -> Error "a card's encryption key does not decode"

type read = {
  text : string option;  (** None when sealed to someone else, or dropped *)
  voice : string;
  recipient : string option;  (** an identity *)
  reply_to : string option;
}

let voice_of j =
  match str_field "voice" j with
  | Some v when List.mem v voices -> v
  | _ -> "agent"

(* Read a content body, opening it with this member's encryption key when it is sealed. *)
let read ~(enc : Crypto.encryption_key option) ~kind
    (body : Yojson.Safe.t option) =
  match body with
  | None -> { text = None; voice = "agent"; recipient = None; reply_to = None }
  | Some b ->
      let reply_to = str_field "reply_to" b in
      if List.mem kind directed_kinds then
        let opened =
          match (enc, get "sealed" b) with
          | Some k, Some sealed ->
              Result.to_option (Digestif_mail.Seal.open_ ~priv:k.secret sealed)
          | _ -> None
        in
        {
          text = Option.bind opened (str_field "text");
          voice = Option.fold ~none:"agent" ~some:voice_of opened;
          recipient = str_field "to" b;
          reply_to;
        }
      else
        {
          (* A reader ignores any text beside a status. *)
          text =
            (if status_of (Some b) <> None then None else str_field "text" b);
          voice = voice_of b;
          recipient = str_field "to" b;
          reply_to;
        }
