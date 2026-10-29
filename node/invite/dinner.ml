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
  match Ptime.add_span now ttl with
  | Some t -> t
  | None -> invalid_arg "invite expiry out of range"

let invite_guest ~relay ~expires_at guest =
  let code = { Invite_code.relay; secret = Invite_code.random_secret () } in
  { guest; code; invite_key = Invite_code.invite_public_key code; expires_at }

(* Every guest's code names the first relay; the dinner itself names them all, so the app
   appends its join to every relay once it has read the dinner. *)
let create ~host ~date ~label ~relays ~now ?(ttl = default_ttl) guests =
  match relays with
  | [] -> Error "A dinner needs at least one relay."
  | relay :: _ ->
      let names =
        List.map (fun g -> String.lowercase_ascii (String.trim g.name)) guests
      in
      if guests = [] then Error "Name at least one guest."
      else if List.exists (fun n -> n = "") names then
        Error "Every guest needs a name."
      else if List.length (List.sort_uniq compare names) <> List.length names
      then
        Error
          "Two guests have the same name; the dinner message names each guest \
           once."
      else
        let expires_at = expiry ~now ttl in
        Ok
          {
            host;
            date;
            label;
            relays;
            invites = List.map (invite_guest ~relay ~expires_at) guests;
          }

(* The protocol's one time format (Time_fmt), for the Ptime values this library computes with. *)
let iso8601 t = Digestif_core.Time_fmt.of_unix (Ptime.to_float_s t)

let parse_time s =
  Option.bind (Digestif_core.Time_fmt.to_unix s) Ptime.of_float_s

let body t : Yojson.Safe.t =
  Digestif_core.Bodies.dinner_json
    {
      host = t.host;
      date = t.date;
      label = t.label;
      guests =
        List.map
          (fun i ->
            {
              Digestif_core.Bodies.name = i.guest.name;
              invite_key = i.invite_key;
              expires_at = iso8601 i.expires_at;
            })
          t.invites;
      relays = t.relays;
    }

(* The dinner envelope, signed by the host's device key. A node writes it with Node.write, which
   takes seq, prev and epoch from its own chain; this is the same act for a caller holding those. *)
let sign ~(host_device : Digestif_core.Crypto.signing_key) ~seq ?prev ~epoch
    ~now t =
  Digestif_core.Envelope.create ~key:host_device ~seq ?prev
    ~created_at:(iso8601 now) ~epoch ~kind:"dinner" (body t)

(* ---- reading a dinner body back, as the guest's app and the host's watcher do ---- *)

type listed_guest = {
  listed_name : string;
  listed_key : string;
  listed_expires_at : Ptime.t;
}

type parsed = {
  parsed_host : string;
  guests : listed_guest list;
  parsed_relays : string list;
}

let parse (body : Yojson.Safe.t) =
  match Digestif_core.Bodies.parse_dinner body with
  | Error m -> Error ("malformed dinner: " ^ m)
  | Ok d -> (
      let guests =
        List.map
          (fun (g : Digestif_core.Bodies.guest) ->
            Option.map
              (fun t ->
                {
                  listed_name = g.name;
                  listed_key = g.invite_key;
                  listed_expires_at = t;
                })
              (parse_time g.expires_at))
          d.guests
      in
      match (List.for_all Option.is_some guests, d.relays) with
      | false, _ ->
          Error "malformed dinner: a guest's expires_at does not parse"
      | true, [] -> Error "malformed dinner: it lists no relay"
      | true, relays ->
          Ok
            {
              parsed_host = d.host;
              guests = List.filter_map Fun.id guests;
              parsed_relays = relays;
            })

let find_guest parsed key =
  List.find_opt (fun g -> g.listed_key = key) parsed.guests
