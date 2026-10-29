(* An ask in the node's ask store (Asks) and the sealed ask body the digest appends for it
   (Ask, docs/protocol.md, Asks and decisions): the store keeps one recommended option by id, the
   body marks it on the option. *)

open Digestif_core
open Digestif_mail

let to_body (a : Asks.t) : Ask.t =
  {
    title = a.title;
    detail = a.detail;
    about = a.about;
    options =
      List.map
        (fun (c : Asks.choice) ->
          { Ask.id = c.id; label = c.label; recommended = c.id = a.recommended })
        a.options;
    on_no_answer = a.on_no_answer;
    lapses_at = a.lapses_at;
  }

(* A store ask from an ask's plaintext. One with no option marked recommended recommends what
   stands when it lapses. *)
let of_body ~key (a : Ask.t) : Asks.t =
  {
    key;
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
