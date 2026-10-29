(* The daily digest (docs/protocol.md, The digest, Answer links, Mailer routes). Once a day, after
   the member's digest hour, the node appends each ask a behavior queued (Ask.body), writes the
   digest with a pre-signed decision behind every option (Digest.write), keeps the mail request
   sealed to the mailing relay, and appends everything on the next sync. The request goes to the
   mailing relay only once the digest is there, and is dropped as soon as the relay answers sent or
   already_sent, which is the only place the link secrets live. What the node's update passes found
   for the person (update-report.json) goes in as the Updates section, and leaves the report only
   once the digest is appended, so a digest that fails to write loses none of it. *)

open Digestif_core
open Digestif_mail

let k_email = "digest_email"
let k_hour = "digest_hour"
let k_last_date = "last_digest_date"
let k_last_at = "last_digest_at"
let default_hour = 7
let ( let* ) = Result.bind

let hour (node : Node.t) =
  match Option.bind (Log.get_config node.log k_hour) int_of_string_opt with
  | Some h when h >= 0 && h < 24 -> h
  | _ -> default_hour

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

(* Due once per local day, at or after the member's digest hour. *)
let due (node : Node.t) ~now =
  let today = local_date now in
  Log.get_config node.log k_email <> None
  && (Unix.localtime now).tm_hour >= hour node
  &&
  match Log.get_config node.log k_last_date with
  | Some d -> d < today
  | None -> true

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
    View.feed node.log fold
    |> List.filter (fun (r : Log.row) ->
        let e = r.signed.envelope in
        List.mem e.kind shown
        && match since with Some s -> e.created_at > s | None -> true)
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

let subject ~now ~came_in ~went_out ~asks =
  Printf.sprintf "Digestif, %s: %d in, %d out, %s" (day_label now) came_in
    went_out (plural asks "ask" "asks")

type written = { digest : string; asks : string list; relay : string }

(* Write today's digest into the log and keep its mail request. One transaction: the asks leave
   the queue, the mail key's counter moves and the digest lands together or not at all. *)
let write (node : Node.t) ~now =
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
        let asks =
          List.map
            (fun (id, (ask : Ask.t)) ->
              let hash, _ =
                match
                  Node.write node ~kind:"ask" (Ask.body ~member_key ask)
                with
                | Ok v -> v
                | Error e -> failwith e
              in
              Store.drop_pending_ask node.log id;
              (hash, ask))
            (Store.pending_asks node.log)
        in
        let sections, came_in, went_out =
          sections node fold
            ~since:(Log.get_config node.log k_last_at)
            ~identity
        in
        let sections =
          match updates with
          | Some (title, lines) -> sections @ [ { Digest.title; lines } ]
          | None -> sections
        in
        let seq, prev = Node.next_position node device_key in
        let created_at = Time_fmt.of_unix now in
        let w =
          Digest.write ~device_key ~seq ?prev ~epoch:fold.epoch ~created_at
            ~date:(local_date now) ~to_
            ~subject:(subject ~now ~came_in ~went_out ~asks:(List.length asks))
            ~sections ~asks ~mail_key ~next_mail_seq:(Mail_key.next_seq node)
            ~member_key ~mailer_key ()
        in
        let digest = Node.store node w.signed in
        Store.add_mail_request node.log ~digest ~relay
          (Digest.mail_request ~mailer_key w);
        Log.set_config node.log k_last_date (local_date now);
        Log.set_config node.log k_last_at created_at;
        Ok { digest; asks = List.map fst asks; relay })
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
