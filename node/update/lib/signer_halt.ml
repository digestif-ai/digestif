(* The admission halt (docs/protocol.md, Approvals; docs/releases.md, Revoking a release key): while
   a revoked key is in the signer set no admission counts, no node starts an approval but a removal
   or a replacement, and every approval of another kind still waiting ends unsent. It lifts on the
   node the moment a signer-set change without the revoked key is adopted (Circle_signer_set), and
   nothing is stored for it: it is read from the update state on every ask. *)

open Release

(* The signers of [trust] whose key is revoked: the halt holds while this is not empty. *)
let revoked (trust : Policy.trust) = Policy.halted trust

(* The revoked signers of the update state at [state_path]; none when it cannot be read, since a
   node with no update state holds only its build's set, which no revocation reached. *)
let of_state_path state_path =
  match State.load state_path with Ok st -> revoked st.trust | Error _ -> []

(* The revoked admins of [node]'s circle: its own admins' when its root names them
   (Circle_admins), else the update state's as [of_state_path] reads them. *)
let of_node ~state_path (node : Node.t) =
  match Circle_admins.of_fold node (Node.fold node) with
  | Some trust -> revoked trust
  | None -> of_state_path state_path

let names (signers : signer list) =
  String.concat " and " (List.map (fun (s : signer) -> s.name) signers)

(* Whether an approval of [kind] still lifts the halt: a removal or a replacement takes the revoked
   key out, so it is the one approval that starts, and goes on waiting, while the halt holds. *)
let lifts = function
  | Approval.Removal | Approval.Replacement -> true
  | Approval.Invite | Approval.Promotion -> false

(* The halt as every admin is shown it (DES-85466, While a revoked key is in the set): the title of
   the Invites halted item and Members' status line, and the act that lifts it. *)
let title halted =
  Printf.sprintf "Invites halted: %s's key is revoked" (names halted)

let what_lifts halted =
  Printf.sprintf "Remove %s as admin to lift it." (names halted)

(* What a node answers when asked to start an approval of [kind] while [halted] names the revoked
   signers, or None when it may start. *)
let refusal ~(halted : signer list) kind =
  match halted with
  | [] -> None
  | _ when lifts kind -> None
  | _ -> Some (title halted ^ ". " ^ what_lifts halted)

(* Whether an approval of [kind] still waiting ends unsent, its state halted: while the halt holds,
   every approval but a removal or a replacement. *)
let ends ~(halted : signer list) kind = halted <> [] && not (lifts kind)

(* Starting a dinner that admits guests: refused while the halt holds, as an invite approval is. *)
let admission_refusal ~halted = refusal ~halted Approval.Invite

(* This machine's own release key, as signer.json's public_key names it: the admin a node speaks
   for, so its Members page and its Invites halted item know the member is one. None without one. *)
let own_key () =
  let path = Sign_next.config_path () in
  if not (Sys.file_exists path) then None
  else
    match Sign_next.load_config path with
    | Ok c -> c.public_key
    | Error _ -> None
