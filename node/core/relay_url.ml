(* Which relay URLs a node takes from another member. A relay message makes every node in the circle
   read from and push to its URL, so the URL must name a public relay over https: never plain http,
   another scheme, a name that resolves on the member's own machine or network, or an address
   literal in a private, loopback or link-local range. A member's own `digestif relay add` and the
   invite they joined with are their own choice, which is how a relay under development at
   http://127.0.0.1:8787 is reached. *)

let host_of url =
  let prefix = "https://" in
  if not (String.starts_with ~prefix url) then None
  else
    let rest =
      String.sub url (String.length prefix)
        (String.length url - String.length prefix)
    in
    let authority =
      match String.index_from_opt rest 0 '/' with
      | Some i -> String.sub rest 0 i
      | None -> rest
    in
    if String.contains authority '@' || authority = "" then None
    else
      let host =
        match String.rindex_opt authority ':' with
        | Some i when not (String.contains authority ']') ->
            String.sub authority 0 i
        | _ -> authority
      in
      if host = "" then None else Some (String.lowercase_ascii host)

let ipv4 host =
  match String.split_on_char '.' host |> List.map int_of_string_opt with
  | [ Some a; Some b; Some c; Some d ]
    when List.for_all (fun x -> x >= 0 && x <= 255) [ a; b; c; d ] ->
      Some (a, b)
  | _ -> None

let private_ipv4 (a, b) =
  a = 0 || a = 10 || a = 127
  || (a = 169 && b = 254)
  || (a = 172 && b >= 16 && b <= 31)
  || (a = 192 && b = 168)
  || (a = 100 && b >= 64 && b <= 127)

let local_name host =
  host = "localhost"
  || String.ends_with ~suffix:".localhost" host
  || String.ends_with ~suffix:".local" host
  || String.ends_with ~suffix:".internal" host
  || not (String.contains host '.')

(* An IPv6 literal is refused outright: a relay is reached by name. *)
let from_circle url =
  match host_of url with
  | None -> false
  | Some host when String.starts_with ~prefix:"[" host -> false
  | Some host -> (
      match ipv4 host with
      | Some ab -> not (private_ipv4 ab)
      | None -> not (local_name host))

(* A circle's address on a relay that hosts many circles (docs/protocol.md, Hosted circles):
   <base>/c/<root hex>, where the root hex is the 64 hex digits of its root hash. A root's relays
   name each relay's base url; a node keeps the address as its relay url. *)

let root_hex root =
  if String.starts_with ~prefix:Keys.sha256_prefix root then
    String.sub root
      (String.length Keys.sha256_prefix)
      (String.length root - String.length Keys.sha256_prefix)
  else root

let strip_slash u =
  if String.length u > 1 && String.ends_with ~suffix:"/" u then
    String.sub u 0 (String.length u - 1)
  else u

let is_hex64 s =
  String.length s = 64
  && String.for_all (fun c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) s

let address ~base ~root = strip_slash base ^ "/c/" ^ root_hex root

(* The base url and root an address names, or None for a url that names no circle (a base url, the
   address every node used before relays hosted many circles). *)
let split_address url =
  let url = strip_slash url in
  let n = String.length url in
  if n < 68 then None
  else
    let hex = String.sub url (n - 64) 64 in
    if String.sub url (n - 67) 3 = "/c/" && is_hex64 hex then
      Some (String.sub url 0 (n - 67), Keys.sha256_prefix ^ hex)
    else None

(* The relay's base url, whether [url] is a base url or a circle's address there. *)
let base_of url =
  match split_address url with Some (b, _) -> b | None -> strip_slash url

(* The host a voucher names: the authority of the base url as the founding node addresses it,
   host and port, as a URL's host reads. *)
let voucher_host url =
  let url = base_of url in
  let rest =
    match String.index_opt url ':' with
    | Some i
      when i + 3 <= String.length url && String.sub url i 3 = "://" ->
        String.sub url (i + 3) (String.length url - i - 3)
    | _ -> url
  in
  let authority =
    match String.index_opt rest '/' with
    | Some i -> String.sub rest 0 i
    | None -> rest
  in
  let authority = String.lowercase_ascii authority in
  (* A URL's host leaves out the scheme's default port. *)
  let drop suffix s =
    if String.ends_with ~suffix s then
      String.sub s 0 (String.length s - String.length suffix)
    else s
  in
  if String.starts_with ~prefix:"https://" url then drop ":443" authority
  else drop ":80" authority

(* A root's short form on every screen: its first 12 hex digits (docs/design.md, Circles). *)
let short_root root =
  let hex = root_hex root in
  if String.length hex <= 12 then hex else String.sub hex 0 12
