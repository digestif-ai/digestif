(* The invite email, one per guest. The host sends it from their own address, so the guest
   recognizes who it is from; the node only writes it and offers a mailto: link. *)

type release = { platform : Dinner.platform; url : string }

let platform_name = function Dinner.Mac -> "Mac" | Dinner.Linux -> "Linux"

let default_releases =
  [ { platform = Dinner.Mac; url = "https://github.com/mbryzek/digestif/releases/latest" };
    { platform = Dinner.Linux; url = "https://github.com/mbryzek/digestif/releases/latest" } ]

type t = { to_ : string; subject : string; text : string }

let readable_expiry t =
  let (y, m, d), ((hh, mm, _), _) = Ptime.to_date_time t in
  let months =
    [| "January"; "February"; "March"; "April"; "May"; "June"; "July"; "August"; "September";
       "October"; "November"; "December" |]
  in
  Printf.sprintf "%s %d, %d at %02d:%02d UTC" months.(m - 1) d y hh mm

let release_lines releases (guest : Dinner.guest) =
  let chosen =
    match guest.platform with
    | Some p -> List.filter (fun r -> r.platform = p) releases
    | None -> releases
  in
  List.map (fun r -> Printf.sprintf "  %s: %s" (platform_name r.platform) r.url) chosen

let render ~host_name ~(dinner : Dinner.t) ?(releases = default_releases) (invite : Dinner.invite) =
  let first_name =
    match String.index_opt invite.guest.name ' ' with
    | Some i -> String.sub invite.guest.name 0 i
    | None -> invite.guest.name
  in
  let lines =
    [ Printf.sprintf "Hi %s," first_name;
      "";
      Printf.sprintf
        "Thanks for coming to %s. I'd like you in Digestif, where our agents keep the conversation going after dinner."
        dinner.label;
      "";
      "1. Install the app:" ]
    @ release_lines releases invite.guest
    @ [ "";
        "2. Open the app and paste this invite code:";
        "";
        "  " ^ Invite_code.to_text invite.code;
        "";
        "   or open this link once the app is installed:";
        "  " ^ Invite_code.to_url invite.code;
        "";
        Printf.sprintf "The code is yours alone and works once, until %s." (readable_expiry invite.expires_at);
        "Please tell me when you have installed it, so I know the join is you.";
        "";
        host_name ]
  in
  { to_ = invite.guest.email;
    subject = Printf.sprintf "Your Digestif invite from %s" dinner.label;
    text = String.concat "\n" lines }

let percent_encode s =
  let b = Buffer.create (String.length s * 3) in
  String.iter
    (fun c ->
      match c with
      | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' | '~' -> Buffer.add_char b c
      | c -> Buffer.add_string b (Printf.sprintf "%%%02X" (Char.code c)))
    s;
  Buffer.contents b

let mailto t =
  Printf.sprintf "mailto:%s?subject=%s&body=%s" (percent_encode t.to_) (percent_encode t.subject)
    (percent_encode t.text)
