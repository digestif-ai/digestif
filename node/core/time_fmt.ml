(* ISO 8601 UTC with a Z and millisecond precision, the protocol's one time format. *)

let of_unix t =
  let ms = int_of_float (Float.round (Float.rem t 1.0 *. 1000.0)) in
  let t, ms = if ms >= 1000 then (t +. 1.0, 0) else (t, ms) in
  let g = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ" (g.tm_year + 1900)
    (g.tm_mon + 1) g.tm_mday g.tm_hour g.tm_min g.tm_sec ms

let now () = of_unix (Unix.gettimeofday ())

(* Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm). *)
let days_from_civil y m d =
  let y = if m <= 2 then y - 1 else y in
  let era = (if y >= 0 then y else y - 399) / 400 in
  let yoe = y - (era * 400) in
  let mp = (m + 9) mod 12 in
  let doy = (((153 * mp) + 2) / 5) + d - 1 in
  let doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy in
  (era * 146097) + doe - 719468

(* A whole-second ISO 8601 date time written in a UTC offset of whole minutes:
   2026-11-01T03:50:00-05:00. Not the protocol's form: this one is handed to a person's own programs,
   which read the local day in it. *)
let of_unix_at_offset ~offset_minutes t =
  let g = Unix.gmtime (Float.floor t +. float_of_int (offset_minutes * 60)) in
  let sign = if offset_minutes < 0 then '-' else '+' in
  let abs_offset = abs offset_minutes in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d%c%02d:%02d" (g.tm_year + 1900)
    (g.tm_mon + 1) g.tm_mday g.tm_hour g.tm_min g.tm_sec sign (abs_offset / 60)
    (abs_offset mod 60)

(* The machine's UTC offset at [t], in minutes east of UTC, daylight saving honoured. The zone is
   read as it stands now: glibc's localtime_r reads TZ once per process, and mktime is the call
   that makes it read again. *)
let local_offset_minutes t =
  ignore (Unix.mktime (Unix.gmtime 0.));
  let seconds (g : Unix.tm) =
    (days_from_civil (g.tm_year + 1900) (g.tm_mon + 1) g.tm_mday * 86400)
    + (g.tm_hour * 3600) + (g.tm_min * 60) + g.tm_sec
  in
  (seconds (Unix.localtime t) - seconds (Unix.gmtime t)) / 60

(* [t] in the machine's zone, with the offset in force at [t]. *)
let of_unix_local t =
  of_unix_at_offset ~offset_minutes:(local_offset_minutes t) t

(* Parse the protocol form (and tolerate missing or longer fractions) to seconds since the epoch. *)
let to_unix s =
  try
    Scanf.sscanf s "%4d-%2d-%2dT%2d:%2d:%2d%s" (fun y mo d h mi sec rest ->
        let frac, z =
          if String.length rest > 0 && rest.[0] = '.' then (
            let i = ref 1 in
            while
              !i < String.length rest && rest.[!i] >= '0' && rest.[!i] <= '9'
            do
              incr i
            done;
            ( float_of_string ("0" ^ String.sub rest 0 !i),
              String.sub rest !i (String.length rest - !i) ))
          else (0.0, rest)
        in
        if z <> "Z" then None
        else
          Some
            (float_of_int
               ((days_from_civil y mo d * 86400) + (h * 3600) + (mi * 60) + sec)
            +. frac))
  with _ -> None
