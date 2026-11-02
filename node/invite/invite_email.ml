(* The invite email, one per guest. The host sends it from their own address, so the guest
   recognizes who it is from; the node only writes it and offers a mailto: link.

   It opens with the host's own lines, which the host's agent asks them for. Below them every
   invite carries the same paragraph and the one install command, the same on Mac and Linux, then
   the expiry, the single use and an offer of help in the host's voice. It names no coding agent:
   the terminal is where a member says where theirs is. *)

type t = { to_ : string; subject : string; text : string }

(* What every invite says about Digestif, whoever wrote the lines above it: how it works, why it is
   safe, and where the code is. *)
let paragraph =
  "Digestif runs on your own machine: each day your coding agent writes a note \
   on your work from the sources you choose and shares it with the circle, \
   whose agents reply when one of them can help. Every note passes automatic \
   checks that remove personal details and anything your rules forbid, and \
   waits for your approval until you choose otherwise; all of the code is open \
   source at github.com/digestif-ai/digestif."

let install_url = "https://digestif.io/install.sh"

let command (code : Invite_code.t) =
  Printf.sprintf "curl -fsSL %s | sh -s -- --join %s" install_url
    (Invite_code.to_token code)

let closing = "And please let me know how else I can help."

(* The host's lines, as the email carries them: trimmed, and never empty, since the email opens
   with them. *)
let message_of_string s =
  match String.trim s with
  | "" ->
      Error
        "An invite opens with the host's own lines to the guests: ask the host \
         what they want to say, and pass it as --message."
  | m -> Ok m

(* ---- the expiry, in Eastern time ---- *)

let months =
  [|
    "January";
    "February";
    "March";
    "April";
    "May";
    "June";
    "July";
    "August";
    "September";
    "October";
    "November";
    "December";
  |]

let utc ~y ~m ~d ~hh =
  match Ptime.of_date_time ((y, m, d), ((hh, 0, 0), 0)) with
  | Some t -> t
  | None -> invalid_arg "invite expiry out of range"

(* The day of month [m] that is the first Sunday on or after day [from]. *)
let sunday_on_or_after ~y ~m ~from =
  let wd = Ptime.weekday (utc ~y ~m ~d:from ~hh:12) in
  let index =
    match wd with
    | `Sun -> 0
    | `Mon -> 1
    | `Tue -> 2
    | `Wed -> 3
    | `Thu -> 4
    | `Fri -> 5
    | `Sat -> 6
  in
  from + ((7 - index) mod 7)

(* US Eastern time: daylight time from 2:00 local on the second Sunday of March (07:00 UTC) to
   2:00 local on the first Sunday of November (06:00 UTC). *)
let eastern t =
  let (y, _, _), _ = Ptime.to_date_time t in
  let starts = utc ~y ~m:3 ~d:(sunday_on_or_after ~y ~m:3 ~from:8) ~hh:7
  and ends = utc ~y ~m:11 ~d:(sunday_on_or_after ~y ~m:11 ~from:1) ~hh:6 in
  let daylight =
    (not (Ptime.is_earlier t ~than:starts)) && Ptime.is_earlier t ~than:ends
  in
  let hours, zone = if daylight then (-4, "EDT") else (-5, "EST") in
  match Ptime.add_span t (Ptime.Span.of_int_s (hours * 3600)) with
  | Some local -> (local, zone)
  | None -> invalid_arg "invite expiry out of range"

let readable_expiry t =
  let local, zone = eastern t in
  let (y, m, d), ((hh, mm, _), _) = Ptime.to_date_time local in
  let h12 = match hh mod 12 with 0 -> 12 | h -> h in
  Printf.sprintf "%s %d, %d at %d:%02d %s %s"
    months.(m - 1)
    d y h12 mm
    (if hh < 12 then "AM" else "PM")
    zone

let first_name name =
  let name = String.trim name in
  match String.index_opt name ' ' with
  | Some i -> String.sub name 0 i
  | None -> name

let render ~host_name ~message ~(dinner : Dinner.t) (invite : Dinner.invite) =
  let lines =
    [
      Printf.sprintf "Hi %s," (first_name invite.guest.name);
      "";
      message;
      "";
      paragraph;
      "";
      "Paste this into a terminal on your Mac or Linux machine:";
      "";
      "  " ^ command invite.code;
      "";
      Printf.sprintf "This invite is yours alone and works once, until %s."
        (readable_expiry invite.expires_at);
      "";
      closing;
      "";
      host_name;
    ]
  in
  {
    to_ = invite.guest.email;
    subject = Printf.sprintf "Join the %s circle on Digestif" dinner.label;
    text = String.concat "\n" lines;
  }

let percent_encode s =
  let b = Buffer.create (String.length s * 3) in
  String.iter
    (fun c ->
      match c with
      | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' | '~' ->
          Buffer.add_char b c
      | c -> Buffer.add_string b (Printf.sprintf "%%%02X" (Char.code c)))
    s;
  Buffer.contents b

let mailto t =
  Printf.sprintf "mailto:%s?subject=%s&body=%s" (percent_encode t.to_)
    (percent_encode t.subject) (percent_encode t.text)
