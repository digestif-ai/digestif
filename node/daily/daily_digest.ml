(* The daily digest (docs/protocol.md, The digest, Answer links, Mailer routes). The node's own
   open asks go on the wire as choices from the node, addressed to the member alone, on the pass
   that finds them (append_open), with each one's item hash kept on the ask. Once a day, after the
   member's digest hour, the node writes the digest: its Inbox part, every Draft and New item of
   the member's with a page link, a pre-signed pick behind every option of a choice and an
   Acknowledge link on a notice (Digest.write); its sections; Your agent did. It keeps the mail
   request sealed to the mailing relay and appends everything on the next sync. The request goes
   to the mailing relay only once the digest is there, and is dropped as soon as the relay answers
   sent or already_sent, which is the only place the link secrets live. What the node's update
   passes found for the person (update-report.json) goes in as the Updates section, and leaves
   the report only once the digest is appended, so a digest that fails to write loses none of it.
   An ask raised to be mailed at once (ask_now, the Paused ask) is appended when it is raised and
   makes a digest due on the next pass outside quiet hours. *)

open Digestif_core
open Digestif_mail

let k_email = "digest_email"
let k_hour = "digest_hour"
let k_last_date = "last_digest_date"
let k_last_at = "last_digest_at"

(* The asks appended ahead of the daily digest that a digest carries as soon as it may (ask_now),
   as a JSON list of ask keys. *)
let k_carry = "digest_carry"
let default_hour = 7
let ( let* ) = Result.bind

let hour (node : Node.t) =
  match Option.bind (Log.get_config node.log k_hour) int_of_string_opt with
  | Some h when h >= 0 && h < 24 -> h
  | _ -> default_hour

(* The address the digest is mailed to, trimmed: one @ with text on both sides and no space. The
   mailing relay is the judge of whether it receives mail; this refuses only what cannot be one.
   Setup, Settings and `digestif digest email` all save through it. ISS-50743 *)
let parse_email s =
  let s = String.trim s in
  match String.index_opt s '@' with
  | Some i
    when i > 0
         && i < String.length s - 1
         && String.rindex s '@' = i
         && not (String.exists (fun c -> c = ' ' || c = '\t' || c = '\n') s) ->
      Some s
  | _ -> None

let email (node : Node.t) = Log.get_config node.log k_email

let set_email (node : Node.t) address =
  match parse_email address with
  | Some a ->
      Log.set_config node.log k_email a;
      Ok a
  | None -> Error "Enter an email address, such as you@example.com."

let set_hour (node : Node.t) h =
  if h < 0 || h > 23 then Error "The hour is 0 to 23."
  else (
    Log.set_config node.log k_hour (string_of_int h);
    Ok h)

let local_date t =
  let g = Unix.localtime t in
  Printf.sprintf "%04d-%02d-%02d" (g.tm_year + 1900) (g.tm_mon + 1) g.tm_mday

let months =
  [|
    "January";
    "February";
    "March";
    "April";
    "May";
    "June";
    "July";
    "August";
    "September";
    "October";
    "November";
    "December";
  |]

let day_label t =
  let g = Unix.localtime t in
  Printf.sprintf "%s %d" months.(g.tm_mon) g.tm_mday

let carried (node : Node.t) =
  match Log.get_config node.log k_carry with
  | None -> []
  | Some s -> (
      match Yojson.Safe.from_string s with
      | `List l ->
          List.filter_map (function `String k -> Some k | _ -> None) l
      | _ -> []
      | exception Yojson.Json_error _ -> [])

let set_carried (node : Node.t) keys =
  Log.set_config node.log k_carry
    (Yojson.Safe.to_string (`List (List.map (fun k -> `String k) keys)))

(* Due once per local day, at or after the member's digest hour and outside their quiet hours: the
   digest carries every ask, so a digest hour inside quiet hours waits for them to end. An ask the
   node raised to be mailed at once (ask_now) makes it due at any hour, outside quiet hours. *)
let due (node : Node.t) ~now =
  let today = local_date now in
  Log.get_config node.log k_email <> None
  && (not (Quiet_hours.in_effect node.log ~now))
  && (carried node <> []
     || (Unix.localtime now).tm_hour >= hour node
        &&
        match Log.get_config node.log k_last_date with
        | Some d -> d < today
        | None -> true)

(* Append the open ask [a] as the node's choice (Asks_mail.item_body), an item addressed to the
   member alone, and keep the item's hash on it: a pick naming that hash answers the ask. *)
(* ISS-42316: a local ask is refused here, before anything is sealed or mailed. *)
let append (node : Node.t) ~member_key (a : Asks.t) =
  let* identity =
    Option.to_result ~none:"no identity; run digestif init"
      (Log.get_config node.log Node.k_identity)
  in
  let* body = Asks_mail.item_body ~identity ~member_key a in
  let* hash, _ = Node.write node ~kind:"item" body in
  let* () = Asks.appended node.log ~key:a.key ~envelope:hash in
  Ok hash

(* ISS-52614: every open ask not on the wire yet, appended as the node's choice on the pass that
   finds it, so it is in the member's Inbox at once rather than at the digest hour. Answers the
   hashes appended. *)
let append_open (node : Node.t) =
  match Node.encryption_key node with
  | Error _ -> []
  | Ok enc ->
      List.filter_map
        (fun (a : Asks.t) ->
          match append node ~member_key:enc.public a with
          | Ok h -> Some h
          | Error e ->
              Printf.eprintf "%s digest: ask %s: %s\n" (Time_fmt.now ()) a.key e;
              None)
        (Asks.unappended node.log)

(* Raise [ask] under [key] and append it at once, so a phone shows it at its next read, and have
   the next pass write a digest carrying it rather than wait for the digest hour: quiet hours still
   hold it. *)
let ask_now (node : Node.t) ~key (ask : Ask.t) =
  let* encryption = Node.encryption_key node in
  Log.transaction node.log (fun () ->
      let* key = Asks_mail.add ~key node.log ask in
      let* a =
        Option.to_result ~none:("no ask " ^ key) (Asks.find node.log key)
      in
      let* hash = append node ~member_key:encryption.public a in
      set_carried node (key :: List.filter (( <> ) key) (carried node));
      Ok hash)

(* The ask hashes a digest's answer links name, in link order, each once. *)
let link_asks body =
  let links =
    match body with
    | Some (`Assoc f) -> (
        match List.assoc_opt "links" f with Some (`List l) -> l | _ -> [])
    | _ -> []
  in
  List.fold_left
    (fun acc l ->
      match l with
      | `Assoc g -> (
          match List.assoc_opt "ask" g with
          | Some (`String h) when not (List.mem h acc) -> acc @ [ h ]
          | _ -> acc)
      | _ -> acc)
    [] links

(* A digest whose answer links name an ask re-signed beside it (Node.drop_refused) cannot follow
   the ask: each link's pre-signed decision names the old ask as its prev, sealed under a secret
   only the mail request holds, so a relay would refuse every answer from that email. The digest
   is dropped instead (its mail request with it, Store), and the asks it carried are carried again,
   which makes the next pass write a digest pre-signed against the hashes the relays will hold.
   What the dropped digest took as read since the last one (last_digest_at) goes back to the
   digest before it, so its sections are written again. ISS-45474 *)
let resign_digest (node : Node.t) ~moved (r : Log.row) =
  let named = link_asks r.signed.body in
  if not (List.exists (fun h -> List.mem_assoc h moved) named) then Node.Resign
  else
    Node.Drop
      (fun () ->
        let now_named =
          List.map
            (fun h -> Option.value (List.assoc_opt h moved) ~default:h)
            named
        in
        let keys =
          List.filter_map
            (fun (a : Asks.t) ->
              match a.envelope with
              | Some h when List.mem h now_named -> Some a.key
              | _ -> None)
            (Asks.list node.log)
        in
        set_carried node
          (List.filter (fun k -> not (List.mem k keys)) (carried node)
          @ List.rev keys);
        let e = r.signed.envelope in
        if Log.get_config node.log k_last_at = Some e.created_at then
          match
            List.filter_map
              (fun (d : Log.row) ->
                if d.signed.envelope.author = e.author && d.hash <> r.hash then
                  Some d.signed.envelope.created_at
                else None)
              (Log.of_kind node.log "digest")
            |> List.sort (fun a b -> compare b a)
          with
          | last :: _ -> Log.set_config node.log k_last_at last
          | [] -> Log.unset_config node.log k_last_at)

let register_resign_check () =
  Node.register_resign_check ~kind:"digest" resign_digest

let () = register_resign_check ()

(* The relay whose relay body says mailer: true and carries its encryption key. *)
let mailer (node : Node.t) (fold : Fold.t) =
  let ours =
    List.map (fun (r : Log.relay_row) -> r.url) (Log.relays node.log)
  in
  let candidates =
    Hashtbl.fold
      (fun _ (r : Bodies.relay) acc ->
        match r.relay_encryption_key with
        | Some k when r.mailer -> (r.url, k) :: acc
        | _ -> acc)
      fold.relays []
    |> List.sort compare
  in
  match candidates with
  | [] -> Error "no relay in the circle says it mails"
  | _ -> (
      match List.find_opt (fun (u, _) -> List.mem u ours) candidates with
      | None ->
          Error
            ("the mailing relay "
            ^ fst (List.hd candidates)
            ^ " is not one of this node's relays")
      | Some (url, key) ->
          let* raw = Keys.decode_x25519 key in
          Ok (url, raw))

let name_of (fold : Fold.t) author =
  match Fold.identity_of fold author with
  | None -> "Someone"
  | Some id -> (
      match Hashtbl.find_opt fold.cards id with
      | Some (c, _) -> Printf.sprintf "%s (%s)" c.card_name c.agent_name
      | None -> "A member")

(* The words a line can show for a content body: its text, its title, else its kind. *)
let gist kind body =
  let field n =
    match body with Some (`Assoc f) -> List.assoc_opt n f | _ -> None
  in
  match (field "text", field "title") with
  | Some (`String s), _ | None, Some (`String s) ->
      let s = String.trim (List.hd (String.split_on_char '\n' s)) in
      if String.length s > 140 then String.sub s 0 137 ^ "..." else s
  | _ -> kind

let shown = [ "summary"; "question"; "answer"; "proposal" ]

(* What came in from other members and went out from this one since the last digest. *)
let sections (node : Node.t) (fold : Fold.t) ~since ~identity =
  let rows =
    View.feed ~kinds:shown node.log fold
    |> List.filter (fun (r : Log.row) ->
        match since with
        | Some s -> r.signed.envelope.created_at > s
        | None -> true)
  in
  let mine, theirs =
    List.partition
      (fun (r : Log.row) ->
        Fold.identity_of fold r.signed.envelope.author = Some identity)
      rows
  in
  let line (r : Log.row) =
    name_of fold r.signed.envelope.author
    ^ ": "
    ^ gist r.signed.envelope.kind r.signed.body
  in
  let section title rs =
    if rs = [] then [] else [ { Digest.title; lines = List.map line rs } ]
  in
  ( section "Came in" theirs @ section "Went out" mine,
    List.length theirs,
    List.length mine )

let plural n one many = Printf.sprintf "%d %s" n (if n = 1 then one else many)

(* A paused member's subject leads with the stage, and says what came in and went out only when
   something did. *)
let subject ?(paused = false) ~now ~came_in ~went_out ~inbox () =
  let traffic = Printf.sprintf "%d in, %d out" came_in went_out in
  let parts =
    (if paused then [ "paused" ] else [])
    @ (if paused && came_in = 0 && went_out = 0 then [] else [ traffic ])
    @ [ Printf.sprintf "%d in your Inbox" inbox ]
  in
  Printf.sprintf "Digestif, %s: %s" (day_label now) (String.concat ", " parts)

(* ISS-42319 (DES-37153, What the digest says without an ask): what the machine's own pages hold
   that a digest tells an absent member, read by the caller that knows those pages (the node's web
   store, Digestif_web.Digest_lines). [lines] is the "On your machine" section, each line saying
   only what the circle could already know; [told] records them as carried, inside the digest's
   transaction, so a line goes out once. *)
(* ISS-52614: [inbox] is the digest's Inbox part, every Draft and New item of the member's, which
   replaces the asks list; [agent_did] is Your agent did, the review lines of what the member's
   agent did since the last digest. *)
type machine = {
  paused : bool;
  lines : string list;
  inbox : Digest.entry list;
  agent_did : string list;
  told : unit -> unit;
}

let on_your_machine = "On your machine"
let your_agent_did = "Your agent did"

(* With no web store to read the Inbox from, the node's own open choices are the Inbox part: each
   one still open, and not past its deadline, where its default stands. *)
let asks_inbox (node : Node.t) ~now ~member_key =
  List.filter_map
    (fun (a : Asks.t) ->
      match a.envelope with
      | Some hash
        when (not (Asks.local_kind a.kind))
             && not (Asks.lapsed ~now:(Time_fmt.of_unix now) a) ->
          Some
            {
              Digest.item = hash;
              hash = Some hash;
              kind = "choice";
              subject = a.kind;
              title = a.title;
              line = "Choice from your node";
              action =
                Pick
                  {
                    keys = [ member_key ];
                    options =
                      List.map
                        (fun (c : Asks.choice) ->
                          {
                            Ask.id = c.id;
                            label = c.label;
                            recommended = c.id = a.recommended;
                          })
                        a.options;
                    default = Some a.on_no_answer;
                    deadline = a.lapses_at;
                  };
            }
      | _ -> None)
    (Asks.list node.log)

type written = { digest : string; asks : string list; relay : string }

(* Write today's digest into the log and keep its mail request. One transaction: the asks are
   marked appended, the mail key's counter moves and the digest lands together or not at all. A
   day with no ask and no section writes nothing and answers None. *)
let write ?machine (node : Node.t) ~now =
  Store.ensure node.log;
  let* identity =
    Option.to_result ~none:"no identity; run digestif init"
      (Log.get_config node.log Node.k_identity)
  in
  let* to_ =
    Option.to_result ~none:"no digest email; run digestif digest email"
      (Log.get_config node.log k_email)
  in
  let* device_key = Node.device_key node in
  let* mail_key = Node.mail_key node in
  let* encryption = Node.encryption_key node in
  let fold = Node.fold node in
  let* relay, mailer_key = mailer node fold in
  let* () =
    match Fold.find fold (Keys.public mail_key) with
    | Some { role = Mail; revoked_by = None; _ } -> Ok ()
    | _ -> Error "this machine's mail key is not admitted yet"
  in
  let member_key = encryption.public in
  let report_path = Digestif_update.Schedule.report_path node.dir in
  let updates =
    Digestif_update.Report.digest_section
      (Digestif_update.Report.load report_path)
  in
  let* written =
    Log.transaction node.log (fun () ->
        ignore (append_open node);
        let sections, came_in, went_out =
          sections node fold
            ~since:(Log.get_config node.log k_last_at)
            ~identity
        in
        let machine = Option.map (fun f -> f ~now) machine in
        let here =
          match machine with
          | Some { lines = _ :: _ as lines; _ } ->
              [ { Digest.title = on_your_machine; lines } ]
          | _ -> []
        in
        let inbox =
          match machine with
          | Some m -> m.inbox
          | None -> asks_inbox node ~now ~member_key
        in
        let did =
          match machine with
          | Some { agent_did = _ :: _ as lines; _ } ->
              [ { Digest.title = your_agent_did; lines } ]
          | _ -> []
        in
        let sections =
          Option.to_list
            (Decisions.needs_phrase_section (Decisions.needs_phrase node ~now))
          @ here @ sections @ did
        in
        let sections =
          match updates with
          | Some (title, lines) -> sections @ [ { Digest.title; lines } ]
          | None -> sections
        in
        (* A day with nothing in it sends nothing, in every stage: the day is done. *)
        if inbox = [] && sections = [] then begin
          Log.set_config node.log k_last_date (local_date now);
          set_carried node [];
          Ok None
        end
        else
          let seq, prev = Node.next_position node device_key in
          let created_at = Time_fmt.of_unix now in
          let w =
            Digest.write ~device_key ~seq ?prev ~epoch:fold.epoch ~created_at
              ~date:(local_date now) ~to_
              ~subject:
                (subject
                   ?paused:(Option.map (fun (m : machine) -> m.paused) machine)
                   ~now ~came_in ~went_out ~inbox:(List.length inbox) ())
              ~sections ~asks:[] ~inbox ~mail_key
              ~next_mail_seq:(Mail_key.next_seq node) ~member_key ~mailer_key ()
          in
          let digest = Node.store node w.signed in
          Store.add_mail_request node.log ~digest ~relay
            (Digest.mail_request ~mailer_key w);
          Log.set_config node.log k_last_date (local_date now);
          Log.set_config node.log k_last_at created_at;
          set_carried node [];
          Option.iter (fun (m : machine) -> m.told ()) machine;
          Ok
            (Some
               {
                 digest;
                 asks =
                   List.filter_map
                     (fun (e : Digest.entry) ->
                       match e.action with Page _ -> None | _ -> e.hash)
                     inbox;
                 relay;
               }))
  in
  Option.iter
    (fun (_, lines) -> Digestif_update.Report.drop report_path lines)
    updates;
  Ok written

type sent = {
  digest : string;
  result : (Relay_client.mail_status, string) result;
}

(* Send every kept mail request whose digest the mailing relay already holds. A request is dropped
   on sent or already_sent and kept on anything else, to be sent again on a later pass. *)
let send ?(transport = Relay_client.curl) (node : Node.t) =
  Store.ensure node.log;
  match Node.device_key node with
  | Error e -> Error e
  | Ok key ->
      Ok
        (List.filter_map
           (fun (r : Store.mail_request) ->
             if not (Log.held_by node.log ~relay:r.relay r.digest) then None
             else
               let result =
                 match
                   Relay_client.mail transport ~base:r.relay ~key r.request
                 with
                 | Ok status ->
                     Store.drop_mail_request node.log r.digest;
                     Ok status
                 | Error e ->
                     let m = Relay_client.error_to_string e in
                     Store.mail_request_failed node.log r.digest m;
                     Error m
               in
               Some { digest = r.digest; result })
           (Store.mail_requests node.log))
