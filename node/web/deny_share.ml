(* The member's deny list for their phone (docs/protocol.md, The phone): the phone answers a circle
   question in signed plaintext, so it runs the deny layer itself (node/mail/webcrypto/deny.mjs), and
   it reads the member's entries from a `deny_list` envelope sealed to the member's own key. The node
   writes one whenever the list differs from the newest one a key of the member wrote, an empty list
   included, so a phone that finds none knows the machine has not shared it yet and refuses rather
   than checking against nothing. *)

open Digestif_core

let plaintext (entries : Store.deny_entry list) : Yojson.Safe.t =
  `Assoc
    [
      ( "entries",
        `List
          (List.map
             (fun (e : Store.deny_entry) ->
               `Assoc
                 [ ("kind", `String e.d_kind); ("value", `String e.value) ])
             entries) );
    ]

let newest_first (a : Log.row) (b : Log.row) =
  match
    compare b.signed.envelope.created_at a.signed.envelope.created_at
  with
  | 0 -> compare b.hash a.hash
  | c -> c

(* The plaintext of the newest deny list a key of [me] wrote that opens with [enc], if any. *)
let newest (node : Node.t) fold ~me ~(enc : Crypto.encryption_key) =
  let mine (r : Log.row) =
    let a = r.signed.envelope.author in
    Fold.identity_of fold a = Some me || List.mem a (Node.own_keys node)
  in
  Log.of_kind node.log "deny_list"
  |> List.filter mine
  |> List.sort newest_first
  |> List.find_map (fun (r : Log.row) ->
      match Option.bind r.signed.body (Content.get "sealed") with
      | None -> None
      | Some sealed ->
          Result.to_option (Digestif_mail.Seal.open_ ~priv:enc.secret sealed))

(* Write the deny list when it differs from the one the phone would read; [Ok None] when it does not
   or when this node is not an admitted member yet. *)
let publish (node : Node.t) =
  let fold = Node.fold node in
  match
    ( Log.get_config node.log Node.k_identity,
      Log.get_config node.log Node.k_device,
      Node.encryption_key node )
  with
  | Some me, Some device, Ok enc when Fold.identity_of fold device = Some me ->
      let want = plaintext (Store.deny_list node.log) in
      let same p = Yojson.Safe.to_string p = Yojson.Safe.to_string want in
      if Option.fold ~none:false ~some:same (newest node fold ~me ~enc) then
        Ok None
      else
        let body =
          `Assoc
            [
              ( "sealed",
                Digestif_mail.Seal.seal
                  ~recipients:[ enc.public ]
                  want );
            ]
        in
        Result.map (fun (h, _) -> Some h) (Node.write node ~kind:"deny_list" body)
  | _ -> Ok None
