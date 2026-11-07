(* Content bodies (protocol.md, Content bodies). A summary is plaintext:

     summary:   { "text": "...", "voice": "agent", "reply_to": "sha256:...",
                  "prompt": "sha256:...", "suggestion": "sha256:..." }

   Everything a member addresses to someone is an item (Item, Store.Items). *)

open Digestif_core

let feed_kinds = [ "summary" ]
let voices = [ "person"; "agent" ]
let get name = function `Assoc f -> List.assoc_opt name f | _ -> None

let str_field name j =
  match get name j with Some (`String s) -> Some s | _ -> None

let opt_pair name = function Some v -> [ (name, `String v) ] | None -> []

let words ~text ~voice =
  `Assoc [ ("text", `String text); ("voice", `String voice) ]

(* A note carries the id of the prompt that wrote it, and the suggestion it judged when it was
   written in two versions for one (ISS-51009, Suggestions). *)
let summary_body ~text ~voice ?reply_to ?stage ?prompt ?suggestion () :
    Yojson.Safe.t =
  `Assoc
    ([ ("text", `String text); ("voice", `String voice) ]
    @ opt_pair "reply_to" reply_to
    @ opt_pair "stage" stage @ opt_pair "prompt" prompt
    @ opt_pair "suggestion" suggestion)

(* A status note (protocol.md, Content bodies): fixed words, carried as their name and never as
   text, so a reader renders them (Status_note) and nothing from the record can ride along. *)
let statuses = Status_note.statuses

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

type read = {
  text : string option;  (** None when dropped, or on a status note *)
  voice : string;
  reply_to : string option;
}

let voice_of j =
  match str_field "voice" j with
  | Some v when List.mem v voices -> v
  | _ -> "agent"

(* Read a summary body. *)
let read (body : Yojson.Safe.t option) =
  match body with
  | None -> { text = None; voice = "agent"; reply_to = None }
  | Some b ->
      {
        (* A reader ignores any text beside a status. *)
        text = (if status_of (Some b) <> None then None else str_field "text" b);
        voice = voice_of b;
        reply_to = str_field "reply_to" b;
      }
