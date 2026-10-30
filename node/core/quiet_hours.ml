(* The member's quiet hours: a span of local time, "22:00" to "07:00", in which nothing of this node
   reaches its person. Kept in the log's config as "HH:MM-HH:MM"; an empty value means none. The
   daily digest, which carries every ask, waits for the span to end, and behaviors read the same
   span through the local API before they reach the person any other way. A span whose start is
   after its end runs past midnight. *)

type t = { start : int; stop : int  (** minutes after local midnight *) }

let key = "quiet_hours"

let minutes_of_string s =
  match String.split_on_char ':' (String.trim s) with
  | [ h; m ] when String.length h = 2 && String.length m = 2 -> (
      match (int_of_string_opt h, int_of_string_opt m) with
      | Some h, Some m when h >= 0 && h < 24 && m >= 0 && m < 60 ->
          Some ((h * 60) + m)
      | _ -> None)
  | _ -> None

let minutes_to_string m = Printf.sprintf "%02d:%02d" (m / 60) (m mod 60)

let make ~start ~stop =
  match (minutes_of_string start, minutes_of_string stop) with
  | None, _ -> Error `Start
  | _, None -> Error `Stop
  | Some a, Some b when a = b -> Error `Empty
  | Some start, Some stop -> Ok { start; stop }

let start_string t = minutes_to_string t.start
let stop_string t = minutes_to_string t.stop
let to_string t = start_string t ^ "-" ^ stop_string t

let of_string s =
  match String.split_on_char '-' s with
  | [ a; b ] -> Result.to_option (make ~start:a ~stop:b)
  | _ -> None

let get log = Option.bind (Log.get_config log key) of_string
let set log t = Log.set_config log key (to_string t)
let clear log = Log.set_config log key ""

let local_minute now =
  let g = Unix.localtime now in
  (g.tm_hour * 60) + g.tm_min

let active t ~now =
  let m = local_minute now in
  if t.start < t.stop then m >= t.start && m < t.stop
  else m >= t.start || m < t.stop

(* The next moment, at or after [now], the local clock reads the span's end. *)
let ends_at t ~now =
  let g = Unix.localtime now in
  let at day =
    fst
      (Unix.mktime
         {
           g with
           tm_mday = g.tm_mday + day;
           tm_hour = t.stop / 60;
           tm_min = t.stop mod 60;
           tm_sec = 0;
         })
  in
  let today = at 0 in
  if today > now then today else at 1

(* Whether the member's quiet hours, if any, hold at [now]. *)
let in_effect log ~now =
  match get log with Some t -> active t ~now | None -> false
