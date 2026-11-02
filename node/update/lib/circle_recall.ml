(* A recall carried on the circle as a release_recall message (docs/protocol.md), so it reaches a
   node within a sync rather than at its next daily read of the channel. The body is the channel's
   recall document, byte for byte in base64url, and the signatures from its .sig.json, so it
   verifies exactly as the channel's copy does. Nothing is stored from it: the node reads the
   circle's recalls after every sync and counts them with the channel's on its update pass
   (Recall), against its own signer set. *)

open Release

let kind = "release_recall"
let to_body (r : recall signed) : Yojson.Safe.t = body_of_signed r

let of_body (json : Yojson.Safe.t) : (recall signed, string) result =
  signed_of_body recall_of_string json

(* Every release_recall the fold applied (an admitted, unrevoked device key wrote it, with both
   fields), in the order the log holds them. One whose document does not parse is recorded as a
   fault the member is shown and left out. Whether a recall counts is the update pass's question:
   a signer outside the node's set changes nothing there. *)
let from_circle (node : Node.t) (fold : Fold.t) : recall signed list =
  let applied = Hashtbl.create 64 in
  List.iter (fun h -> Hashtbl.replace applied h ()) fold.applied;
  List.filter_map
    (fun (row : Log.row) ->
      if not (Hashtbl.mem applied row.hash) then None
      else
        match of_body (Option.value row.signed.body ~default:`Null) with
        | Ok r -> Some r
        | Error e ->
            Log.add_fault node.log ~kind ~author:row.signed.envelope.author
              ~seq:row.signed.envelope.seq
              ~detail:(row.hash ^ " " ^ e);
            None)
    (Log.of_kind node.log kind)
