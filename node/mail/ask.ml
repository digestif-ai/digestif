(* An ask and the decision that answers it (docs/protocol.md, Asks and decisions). Both bodies are
   sealed to the member's own card key: only the member's devices read them. *)

type choice = { id : string; label : string; recommended : bool }

type t = {
  title : string;
  detail : string;
  about : string option;
  options : choice list;
  on_no_answer : string;
  lapses_at : string;
}

let choice_json c =
  `Assoc
    ([ ("id", `String c.id); ("label", `String c.label) ]
    @ if c.recommended then [ ("recommended", `Bool true) ] else [])

let plaintext t =
  `Assoc
    ([ ("title", `String t.title); ("detail", `String t.detail) ]
    @ (match t.about with Some h -> [ ("about", `String h) ] | None -> [])
    @ [
        ("options", `List (List.map choice_json t.options));
        ("on_no_answer", `String t.on_no_answer);
        ("lapses_at", `String t.lapses_at);
      ])

let validate t =
  let ids = List.map (fun c -> c.id) t.options in
  if t.options = [] then Error "an ask needs at least one option"
  else if List.length (List.sort_uniq compare ids) <> List.length ids then
    Error "option ids repeat"
  else if not (List.mem t.on_no_answer ids) then
    Error "on_no_answer is not one of the options"
  else Ok ()

let body ~member_key t =
  `Assoc [ ("sealed", Seal.seal ~recipients:[ member_key ] (plaintext t)) ]

let ( let* ) = Result.bind

let of_plaintext p =
  let str name = Seal.string_member name p in
  let* title = str "title" in
  let* detail = str "detail" in
  let about = Result.to_option (str "about") in
  let* on_no_answer = str "on_no_answer" in
  let* lapses_at = str "lapses_at" in
  let* opts = Seal.member "options" p in
  let* options =
    match opts with
    | `List l ->
        List.fold_right
          (fun o acc ->
            let* acc = acc in
            let* id = Seal.string_member "id" o in
            let* label = Seal.string_member "label" o in
            let recommended = Seal.member "recommended" o = Ok (`Bool true) in
            Ok ({ id; label; recommended } :: acc))
          l (Ok [])
    | _ -> Error "options is not a list"
  in
  Ok { title; detail; about; options; on_no_answer; lapses_at }

(* Read an ask body with the member's encryption private key. *)
let of_body ~priv body =
  let* sealed = Seal.member "sealed" body in
  let* p = Seal.open_ ~priv sealed in
  of_plaintext p

let decision_body ~member_key ~ask ~option =
  `Assoc
    [
      ("ask", `String ask);
      ( "sealed",
        Seal.seal ~recipients:[ member_key ]
          (`Assoc [ ("option", `String option) ]) );
    ]

(* The ask hash and the option id a decision names. *)
let decision_of_body ~priv body =
  let* ask = Seal.string_member "ask" body in
  let* sealed = Seal.member "sealed" body in
  let* p = Seal.open_ ~priv sealed in
  let* option = Seal.string_member "option" p in
  Ok (ask, option)
