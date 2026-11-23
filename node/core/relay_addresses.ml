(* Each node rewrites its own stored relay urls to its circle's address (docs/protocol.md, Hosted
   circles). A url a node stored before relays hosted many circles is a relay's base url, which the
   relay answers as its home circle's unprefixed address. Once that relay answers GET /v0/relay, it
   hosts many circles, and the node reads it at <url>/c/<root hex> from then on, its cursor carried
   across, since the relay ids are the same. A relay that does not answer it yet is asked again the
   next time; one that answered is never asked again, because its url is an address by then. A node
   therefore never depends on reading a rewritten relay message to find the new address. *)

(* Every stored relay url that names no circle and whose relay hosts many circles, rewritten to this
   circle's address there. Answers each (from, to) it rewrote. *)
let rewrite ?(transport = Relay_client.curl) (node : Node.t) =
  match Node.root node with
  | None -> []
  | Some root ->
      List.filter_map
        (fun (r : Log.relay_row) ->
          match Relay_url.split_address r.url with
          | Some _ -> None
          | None -> (
              match Relay_client.relay_info transport ~base:r.url with
              | Ok _ ->
                  let to_ = Relay_url.address ~base:r.url ~root in
                  Log.rename_relay node.log ~from:r.url ~to_;
                  Some (r.url, to_)
              | Error _ -> None))
        (Log.relays node.log)
