(* What a node reads out of its log once the fold has run: the feed (content it believes, in fold
   order), forks and gaps. The local UI and the conformance adapter both read these. *)

let fork_sides (log : Log.t) =
  List.concat_map
    (fun (f : Log.fault) ->
      if f.kind = "fork" then String.split_on_char ' ' f.detail else [])
    (Log.open_faults log)

(* Content envelopes from an author in force when it wrote, minus retracts, retracted targets and
   both sides of every fork, ordered by (created_at, hash). *)
let feed (log : Log.t) (fold : Fold.t) =
  let forked = fork_sides log in
  Log.all log
  |> List.filter (fun (r : Log.row) ->
      let e = r.signed.envelope in
      (not (Envelope.is_circle_state e.kind))
      && e.kind <> "retract" && r.retracted_by = None
      && (not (List.mem r.hash forked))
      && Fold.reads_content fold
           { Fold.hash = r.hash; envelope = e; body = r.signed.body })
  |> List.sort (fun (a : Log.row) (b : Log.row) ->
      match
        compare a.signed.envelope.created_at b.signed.envelope.created_at
      with
      | 0 -> compare a.hash b.hash
      | c -> c)

type fork = { author : string; seq : int; hashes : string list }

let forks (log : Log.t) =
  List.filter_map
    (fun (f : Log.fault) ->
      if f.kind = "fork" then
        Some
          {
            author = f.author;
            seq = f.seq;
            hashes = String.split_on_char ' ' f.detail;
          }
      else None)
    (Log.open_faults log)

(* Missing sequence numbers per chained device key. *)
let gaps (log : Log.t) (fold : Fold.t) =
  let by_author = Hashtbl.create 8 in
  List.iter
    (fun (f : Log.fault) ->
      match Fold.find fold f.author with
      | Some { role = Device; _ } when f.kind = "gap" ->
          Hashtbl.replace by_author f.author
            (f.seq
            :: Option.value (Hashtbl.find_opt by_author f.author) ~default:[])
      | _ -> ())
    (Log.open_faults log);
  Hashtbl.fold
    (fun a seqs acc -> (a, List.sort compare seqs) :: acc)
    by_author []
  |> List.sort compare
