(* An ask in the node's ask store (Asks) and the sealed ask body the digest appends for it
   (Ask, docs/protocol.md, Asks and decisions): the store keeps one recommended option by id, the
   body marks it on the option. A local ask has no body: [to_body] refuses it, so nothing can
   append it to a relay or carry it in a digest email. *)

open Digestif_core
open Digestif_mail

let to_body (a : Asks.t) : (Ask.t, string) result =
  if Asks.local_kind a.kind then
    Error ("ask " ^ a.key ^ " is local and never leaves this machine")
  else
    Ok
      {
        kind = a.kind;
        title = a.title;
        detail = a.detail;
        about = a.about;
        options =
          List.map
            (fun (c : Asks.choice) ->
              {
                Ask.id = c.id;
                label = c.label;
                recommended = c.id = a.recommended;
              })
            a.options;
        on_no_answer = a.on_no_answer;
        lapses_at = a.lapses_at;
      }

(* A store ask from an ask's plaintext. One with no option marked recommended recommends what
   stands when it lapses. *)
let of_body ~key (a : Ask.t) : Asks.t =
  {
    key;
    kind = a.kind;
    title = a.title;
    detail = a.detail;
    about = a.about;
    options =
      List.map
        (fun (c : Ask.choice) -> { Asks.id = c.id; label = c.label })
        a.options;
    recommended =
      (match
         List.find_opt (fun (c : Ask.choice) -> c.recommended) a.options
       with
      | Some c -> c.id
      | None -> a.on_no_answer);
    on_no_answer = a.on_no_answer;
    lapses_at = a.lapses_at;
    raised_at = "";
    answer = None;
    answered_at = None;
    envelope = None;
    answered_via = None;
  }

(* Raise an ask for the next digest. [key] names what it is about, so raising it again replaces
   the open one; without one it is an ask of its own. *)
let add ?key (log : Log.t) (a : Ask.t) =
  let key =
    match key with
    | Some k -> k
    | None -> "ask:" ^ B64url.encode (Crypto.random 9)
  in
  Result.map (fun () -> key) (Asks.raise_ log (of_body ~key a))

(* ISS-52614 (docs/protocol.md, Items): the node's own ask goes on the wire as a choice from the
   node, addressed to the member alone and sealed to their key: its kind is the choice's subject,
   its on_no_answer the default, its lapse the deadline. The node's ask store keeps acting on the
   picks that answer it, so the ask's behaviour is unchanged. *)
let item_subjects = [ "intro"; "share"; "behavior"; "join"; "paused" ]

let item_json (a : Asks.t) : Yojson.Safe.t =
  let opt name = function Some v -> [ (name, `String v) ] | None -> [] in
  `Assoc
    ([ ("kind", `String "choice") ]
    @ opt "subject"
        (Option.bind a.kind (fun k ->
             if List.mem k item_subjects then Some k else None))
    @ [
        ("voice", `String "node");
        ("title", `String a.title);
        ("detail", `String a.detail);
      ]
    @ opt "about" a.about
    @ [
        ( "options",
          `List
            (List.map
               (fun (c : Asks.choice) ->
                 `Assoc
                   ([ ("id", `String c.id); ("label", `String c.label) ]
                   @
                   if c.id = a.recommended then [ ("recommended", `Bool true) ]
                   else []))
               a.options) );
        ("default", `String a.on_no_answer);
      ]
    @ opt "deadline" a.lapses_at)

let item_body ~identity ~member_key (a : Asks.t) =
  if Asks.local_kind a.kind then
    Error ("ask " ^ a.key ^ " is local and never leaves this machine")
  else if List.length a.options < 2 then
    Error ("ask " ^ a.key ^ " has one option; a choice needs two")
  else
    Ok
      (`Assoc
         [
           ("to", `List [ `String identity ]);
           ("sealed", Seal.seal ~recipients:[ member_key ] (item_json a));
         ])
