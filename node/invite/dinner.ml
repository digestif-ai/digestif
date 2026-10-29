(* A dinner's invitations: one random invite keypair per named guest, and the dinner message the
   host's device key signs naming each guest beside the public half and its expiry. *)

type platform = Mac | Linux

type guest = { name : string; email : string; platform : platform option }

type invite = {
  guest : guest;
  code : Invite_code.t;
  invite_key : string;  (** The public half, ed25519:<b64url>. *)
  expires_at : Ptime.t;
}

type t = {
  host : string;  (** The host's identity key. *)
  date : string;  (** YYYY-MM-DD, the night of the dinner. *)
  label : string;
  relays : string list;
  invites : invite list;
}

let default_ttl = Ptime.Span.of_int_s (72 * 3600)

let expiry ~now ttl =
  match Ptime.add_span now ttl with Some t -> t | None -> invalid_arg "invite expiry out of range"

let invite_guest ~relay ~expires_at guest =
  let code = { Invite_code.relay; secret = Invite_code.random_secret () } in
  { guest; code; invite_key = Invite_code.invite_public_key code; expires_at }

(* Every guest's code names the first relay; the dinner itself names them all, so the app
   appends its join to every relay once it has read the dinner. *)
let create ~host ~date ~label ~relays ~now ?(ttl = default_ttl) guests =
  match relays with
  | [] -> Error "A dinner needs at least one relay."
  | relay :: _ ->
      let names = List.map (fun g -> String.lowercase_ascii (String.trim g.name)) guests in
      if guests = [] then Error "Name at least one guest."
      else if List.exists (fun n -> n = "") names then Error "Every guest needs a name."
      else if List.length (List.sort_uniq compare names) <> List.length names then
        Error "Two guests have the same name; the dinner message names each guest once."
      else
        let expires_at = expiry ~now ttl in
        Ok { host; date; label; relays; invites = List.map (invite_guest ~relay ~expires_at) guests }

let body t : Yojson.Safe.t =
  `Assoc
    [ ("host", `String t.host);
      ("dinner", `Assoc [ ("date", `String t.date); ("label", `String t.label) ]);
      ( "guests",
        `List
          (List.map
             (fun i ->
               `Assoc
                 [ ("name", `String i.guest.name);
                   ("invite_key", `String i.invite_key);
                   ("expires_at", `String (Invite_wire.iso8601 i.expires_at)) ])
             t.invites) );
      ("relays", `List (List.map (fun r -> `String r) t.relays)) ]

let sign ~host_device ~seq ?prev ~epoch ~now t =
  Invite_wire.sign_envelope ~author:host_device ~seq ?prev ~created_at:now ~epoch ~kind:"dinner" (body t)

(* ---- reading a dinner body back, as the guest's app and the host's watcher do ---- *)

type listed_guest = { listed_name : string; listed_key : string; listed_expires_at : Ptime.t }

type parsed = { parsed_host : string; guests : listed_guest list; parsed_relays : string list }

let parse (body : Yojson.Safe.t) =
  let open Invite_wire in
  let str = function Some (`String s) -> Some s | _ -> None in
  match str (field "host" body), field "guests" body, field "relays" body with
  | Some host, Some (`List gs), Some (`List rs) -> (
      let guests =
        List.filter_map
          (fun g ->
            match str (field "name" g), str (field "invite_key" g), str (field "expires_at" g) with
            | Some n, Some k, Some e -> (
                match parse_iso8601 e with
                | Some t -> Some { listed_name = n; listed_key = k; listed_expires_at = t }
                | None -> None)
            | _ -> None)
          gs
      in
      let relays = List.filter_map (function `String r -> Some r | _ -> None) rs in
      if List.length guests <> List.length gs || List.length relays <> List.length rs then
        Error "malformed dinner: a guest or relay entry does not parse"
      else Ok { parsed_host = host; guests; parsed_relays = relays })
  | _ -> Error "malformed dinner: host, guests and relays are required"

let find_guest parsed key = List.find_opt (fun g -> g.listed_key = key) parsed.guests
