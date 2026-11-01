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
