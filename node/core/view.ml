(* What a node reads out of its log once the fold has run: the feed (content it believes, in fold
   order), forks and gaps. The local UI and the conformance adapter both read these. *)

let fork_sides (log : Log.t) =
  List.concat_map
    (fun (f : Log.fault) ->
      if f.kind = "fork" then String.split_on_char ' ' f.detail else [])
    (Log.open_faults log)

(* Whether the feed shows [r]: content from an author in force when it wrote, not a retract, not
   retracted, and on neither side of a fork. *)
let believed (log : Log.t) (fold : Fold.t) =
  let forked = fork_sides log in
  fun (r : Log.row) ->
    let e = r.signed.envelope in
    (not (Envelope.is_circle_state e.kind))
    && e.kind <> "retract" && r.retracted_by = None
    && (not (List.mem r.hash forked))
    && Fold.reads_content fold
         { Fold.hash = r.hash; envelope = e; body = r.signed.body }

(* Content envelopes the feed shows, ordered by (created_at, hash). [kinds] narrows it to the kinds a
   reader shows, read by the kind index, so the rest of the log (a digest a night) is never decoded. *)
let feed ?kinds (log : Log.t) (fold : Fold.t) =
  (match kinds with Some k -> Log.of_kinds log k | None -> Log.all log)
  |> List.filter (believed log fold)
  |> List.sort (fun (a : Log.row) (b : Log.row) ->
      match
        compare a.signed.envelope.created_at b.signed.envelope.created_at
      with
      | 0 -> compare a.hash b.hash
      | c -> c)

(* The newest first order of the log's walks: (created_at, hash), descending. *)
let newest (a : Log.row) (b : Log.row) =
  compare
    (b.signed.envelope.created_at, b.hash)
    (a.signed.envelope.created_at, a.hash)

(* At most [limit] envelopes of [kinds] the feed shows, newest first by (created_at, hash): written
   before [before] when it is given (a created_at in the protocol's form), and by one of [authors]
   when it is given. The log is walked newest first, by each author's own index when [authors] is
   given, and the walk stops at the page, so a page costs what it shows, not what the circle ever
   wrote. *)
let page ?before ?authors ~kinds ~limit (log : Log.t) (fold : Fold.t) =
  let shown = believed log fold in
  let where =
    String.concat " AND "
      (("kind IN (" ^ Log.placeholders kinds ^ ")")
      :: (if before = None then [] else [ "created_at < ?" ]))
  in
  let params =
    List.map Log.s kinds @ Option.to_list (Option.map Log.s before)
  in
  let walk author =
    let acc = ref [] and n = ref 0 in
    if limit > 0 then
      Log.newest_first log ?author ~where params (fun r ->
          if shown r then begin
            acc := r :: !acc;
            incr n
          end;
          if !n >= limit then `Stop else `Continue);
    List.rev !acc
  in
  match authors with
  | None -> walk None
  | Some keys ->
      List.concat_map (fun k -> walk (Some k)) keys
      |> List.sort newest
      |> List.filteri (fun i _ -> i < limit)

(* The envelopes of [kinds] the feed shows that answer [hash], oldest first, by the reply_to index:
   no other message is opened to find them. *)
let replies ~kinds (log : Log.t) (fold : Fold.t) hash =
  List.filter (believed log fold) (Log.replies log ~kinds hash)

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
