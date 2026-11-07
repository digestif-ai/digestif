(* The node's own choices (docs/protocol.md, Items: `join` and `paused`) as the node raises them,
   and the pick that answers one. A pick is sealed to the picker's own key and the choice
   author's: for the node's own choices, the member's key alone. *)

type choice = { id : string; label : string; recommended : bool }

type t = {
  kind : string option;  (** The choice's subject: join or paused. *)
  title : string;
  detail : string;
  about : string option;
  options : choice list;
  on_no_answer : string;
  lapses_at : string option;
      (** None: no deadline, and on_no_answer stands for as long as nobody
          picks. *)
}

(* The sentence an answer link's confirm page shows under one option, when the answer acts later
   than the click: the Paused choice's Unpause acts when the machine next reads the relays
   (docs/protocol.md, Answer links). *)
let confirm_note t (c : choice) =
  match (t.kind, c.id) with
  | Some "paused", "unpause" ->
      Some "Your machine unpauses when it next syncs, or when it wakes."
  | _ -> None

(* ISS-52614: a pick on an item choice (docs/protocol.md, Items, Picks): the decision names the
   choice under "item" and is sealed to [keys], the picker's own key and the choice author's. The
   node's own choices are addressed to the member alone, so their picks are sealed to the member's
   key and nothing else. An Acknowledge link answers a notice the same way, naming the option
   [acknowledge]. *)
let acknowledge = "acknowledge"

let pick_body ~keys ~item ~option =
  `Assoc
    [
      ("item", `String item);
      ( "sealed",
        Seal.seal ~recipients:keys (`Assoc [ ("option", `String option) ]) );
    ]

let ( let* ) = Result.bind

(* The item hash and the option id a pick names. *)
let decision_of_body ~priv body =
  let* item = Seal.string_member "item" body in
  let* sealed = Seal.member "sealed" body in
  let* p = Seal.open_ ~priv sealed in
  let* option = Seal.string_member "option" p in
  Ok (item, option)
