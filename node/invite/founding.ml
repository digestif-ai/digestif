(* Founding a circle on the relays a founder's other circles use (docs/design.md, Circles;
   docs/protocol.md, Hosted circles). A relay hosts a new circle when a member of a circle it already
   hosts vouches for the root: the founder's own node for that other circle, on this machine, signs
   the voucher with its device key. Each relay is asked with the root's bootstrap append at the
   circle's address there; a refused relay stays listed in the root, and digestif relay add <url>
   --circle <id> asks it again later with a fresh voucher. *)

open Digestif_core

let ( let* ) = Result.bind

(* One of the founder's circles on this machine: its folder, its root, and the relays it reads, by
   base url, with whether each read clean at its last sync. *)
type other = {
  dir : string;
  root : string;
  relays : (string * bool) list;  (** base url, read clean *)
}

let read_other dir =
  if not (Sys.file_exists (Node.log_path dir)) then None
  else
    let log = Log.open_ (Node.log_path dir) in
    Fun.protect
      ~finally:(fun () -> Log.close log)
      (fun () ->
        match Log.get_config log Node.k_root with
        | None -> None
        | Some root ->
            Some
              {
                dir;
                root;
                relays =
                  List.map
                    (fun (r : Log.relay_row) ->
                      ( Relay_url.base_of r.url,
                        r.last_error = None && r.last_sync_at <> None ))
                    (Log.relays log);
              })

(* Every other circle of the founder's on this machine: each folder under ~/digestif, and the default
   node when no id names it, leaving out [except], the folder being founded. *)
let others ~except () =
  let canon = Node.canonical_dir in
  let dirs = List.map (fun (e : Circles.entry) -> e.dir) (Circles.entries ()) in
  let default = Node.default_dir () in
  let dirs =
    if List.exists (fun d -> canon d = canon default) dirs then dirs
    else dirs @ [ default ]
  in
  List.filter_map
    (fun d -> if canon d = canon except then None else read_other d)
    dirs

(* The relays a founding asks by default: every relay the founder's other circles read, by base url,
   in the order the circles list them, each once. *)
let default_relays others =
  List.fold_left
    (fun acc o ->
      List.fold_left
        (fun acc (b, _) -> if List.mem b acc then acc else acc @ [ b ])
        acc o.relays)
    [] others

(* The circle of the founder's that vouches on the relay at [base]: one that reads it, preferring one
   that read it clean at its last sync. *)
let voucher_circle others ~base =
  let reads clean o = List.mem (base, clean) o.relays in
  match List.find_opt (reads true) others with
  | Some o -> Some o
  | None -> List.find_opt (reads false) others

(* The voucher for [root] on the relay at [base], signed by the founder's device key in the circle that
   vouches there. None when no circle of the founder's reads that relay. *)
let voucher ?now others ~base ~root =
  match voucher_circle others ~base with
  | None -> Ok None
  | Some o ->
      let ks = Keystore.default ~scope:o.dir in
      let* device =
        match Keystore.get_signing_key ks "device" with
        | Ok (Some k) -> Ok k
        | Ok None -> Error ("the node in " ^ o.dir ^ " holds no device key")
        | Error e -> Error e
      in
      Ok (Some (Voucher.sign ?now device ~root ~relay:base ~circle:o.root))

(* What one relay answered the founding append. *)
type answer =
  | Hosted of string  (** the circle's address there *)
  | Refused of { code : string; message : string }
  | Failed of string  (** no answer, or one that names no refusal *)

(* What a refusal means for this founder, and when it clears where it has a time: the relay's own
   message carries the day for too_many_circles. *)
let meaning ~code ~message =
  let tail = if message = "" then "" else " (" ^ message ^ ")" in
  match code with
  | "not_hosting" ->
      "its operator has stopped it hosting new circles; it clears when they \
       turn hosting back on" ^ tail
  | "not_vouched" ->
      "no circle of yours there vouched for this one; it clears once you \
       belong to a circle this relay hosts" ^ tail
  | "too_many_circles" ->
      "you opened as many circles on it as one member may in 30 days" ^ tail
  | "relay_full" ->
      "it reserves room for no more circles; it clears when its operator \
       raises RELAY_STORAGE or a circle leaves" ^ tail
  | "circle_suspended" -> "its operator suspended this circle there" ^ tail
  | _ -> if message = "" then code else message

(* Ask the relay at [base] to host the circle [root], whose root envelope is [signed]: the bootstrap
   append at the circle's address, carrying [voucher]. A duplicate is hosted too: the relay already
   holds the root. *)
let ask ?(transport = Relay_client.curl) ?voucher ~base ~root
    (signed : Envelope.signed) =
  let address = Relay_url.address ~base ~root in
  match
    Relay_client.append ?voucher transport ~base:address ~key:None signed
  with
  | Ok _ -> Hosted address
  | Error (Relay_client.Refused (_, (code, message) :: _)) ->
      Refused { code; message }
  | Error e -> Failed (Relay_client.error_to_string e)

(* The line a founding prints for one relay's answer: the relay, then what it answered, the circle's
   root in its short form. *)
let answer_line ~base ~root = function
  | Hosted address ->
      Printf.sprintf "%s\thosts %s at %s" base
        (Relay_url.short_root root)
        address
  | Refused { code; message } ->
      Printf.sprintf "%s\trefused %s: %s" base code (meaning ~code ~message)
  | Failed e -> Printf.sprintf "%s\tdid not answer: %s" base e

(* Ask every relay in [relays] for [root]: each with a voucher from the founder's circle there, or
   none when no circle of theirs reads it (the relay then refuses not_vouched, or hosts it as its
   home). *)
let ask_all ?transport ?now others ~root (signed : Envelope.signed) relays =
  List.map
    (fun base ->
      let answer =
        match voucher ?now others ~base ~root with
        | Error e -> Failed ("no voucher: " ^ e)
        | Ok voucher -> ask ?transport ?voucher ~base ~root signed
      in
      (base, answer))
    relays

let hosted answers =
  List.filter_map
    (fun (b, a) -> match a with Hosted addr -> Some (b, addr) | _ -> None)
    answers

(* The relay message for the circle's address on a relay that hosts it, written as today's: whether
   the relay mails and its sealing key's public half, read from GET /v0/relay. A url no other node
   would take (Relay_url.from_circle: a relay under development) gets none. *)
let relay_message ?(transport = Relay_client.curl) (node : Node.t) ~address =
  if not (Relay_url.from_circle address) then Ok None
  else
    let mailer, encryption_key =
      match Relay_client.relay_info transport ~base:address with
      | Ok i -> (i.mailer && i.encryption_key <> None, i.encryption_key)
      | Error _ -> (false, None)
    in
    let encryption_key = if mailer then encryption_key else None in
    let* hash, _ =
      Node.write node ~kind:"relay"
        (Bodies.make_relay ~url:address ~mailer ?encryption_key ())
    in
    Ok (Some hash)
