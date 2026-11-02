(* The terminal setup talks to. Under `curl | sh` standard input is the script, so every prompt reads
   /dev/tty, never stdin; with no terminal setup stops before the join and says to run it in one.

   [io] is the whole surface setup uses, so a test drives setup with a script instead of a person. *)

open Digestif_core

type io = {
  say : string -> unit;  (** print a line *)
  ask : string -> string option;
      (** print a prompt, read a line; None at end of input *)
  secret : string -> string option;  (** the same, unechoed *)
  key : string -> char option;  (** print a prompt, read one key *)
  copy : string -> bool;  (** put text on the clipboard; "" clears it *)
}

(* ---- the clipboard ---- *)

let b64_alphabet =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

(* Standard base64 with padding, as the terminal clipboard escape takes it. *)
let base64 s =
  let n = String.length s in
  let b = Buffer.create ((n + 2) / 3 * 4) in
  let byte i = if i < n then Char.code s.[i] else 0 in
  let rec go i =
    if i < n then (
      let v = (byte i lsl 16) lor (byte (i + 1) lsl 8) lor byte (i + 2) in
      let c k = b64_alphabet.[(v lsr (18 - (6 * k))) land 63] in
      Buffer.add_char b (c 0);
      Buffer.add_char b (c 1);
      Buffer.add_char b (if i + 1 < n then c 2 else '=');
      Buffer.add_char b (if i + 2 < n then c 3 else '=');
      go (i + 3))
  in
  go 0;
  Buffer.contents b

(* OSC 52: the terminal's own clipboard escape, which reaches the clipboard of the machine the
   terminal runs on, so it works over SSH where pbcopy, wl-copy and xclip would write the remote
   machine's. *)
let osc52 text = "\027]52;c;" ^ base64 text ^ "\007"

type clipboard = Program of string array | Escape

let set_env v = match Sys.getenv_opt v with Some s -> s <> "" | None -> false

(* pbcopy on macOS; wl-copy or xclip on a Linux desktop; the escape over SSH and anywhere else. *)
let clipboard ~macos ~ssh ~have =
  if ssh then Escape
  else if macos then Program [| "/usr/bin/pbcopy" |]
  else if set_env "WAYLAND_DISPLAY" && have "wl-copy" then
    Program [| "wl-copy" |]
  else if set_env "DISPLAY" && have "xclip" then
    Program [| "xclip"; "-selection"; "clipboard" |]
  else Escape

(* ---- /dev/tty ---- *)

let write_all fd s =
  let b = Bytes.of_string s in
  let rec go off =
    if off < Bytes.length b then
      go (off + Unix.write fd b off (Bytes.length b - off))
  in
  try go 0 with Unix.Unix_error _ -> ()

let read_char fd =
  let b = Bytes.create 1 in
  let rec go () =
    match Unix.read fd b 0 1 with
    | 0 -> None
    | _ -> Some (Bytes.get b 0)
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> go ()
    | exception Unix.Unix_error _ -> None
  in
  go ()

let read_line fd =
  let buf = Buffer.create 128 in
  let rec go () =
    match read_char fd with
    | None -> if Buffer.length buf = 0 then None else Some (Buffer.contents buf)
    | Some ('\n' | '\r') -> Some (Buffer.contents buf)
    | Some c ->
        Buffer.add_char buf c;
        go ()
  in
  go ()

(* Runs [f] with the terminal changed by [change], restoring it however [f] ends. *)
let with_mode fd change f =
  match Unix.tcgetattr fd with
  | exception Unix.Unix_error _ -> f ()
  | saved ->
      (try Unix.tcsetattr fd Unix.TCSANOW (change saved)
       with Unix.Unix_error _ -> ());
      Fun.protect
        ~finally:(fun () ->
          try Unix.tcsetattr fd Unix.TCSANOW saved
          with Unix.Unix_error _ -> ())
        f

let tty ?(macos = Keystore.is_macos ()) () =
  match Unix.openfile "/dev/tty" [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0 with
  | exception Unix.Unix_error _ ->
      Error
        "There is no terminal to ask in. Run the same command in a terminal \
         window; nothing has been spent."
  | fd ->
      let say s = write_all fd (s ^ "\n") in
      let prompt p = if p <> "" then write_all fd (p ^ " ") in
      let ask p =
        prompt p;
        read_line fd
      in
      let secret p =
        prompt p;
        let r =
          with_mode fd
            (fun t -> { t with Unix.c_echo = false })
            (fun () -> read_line fd)
        in
        write_all fd "\n";
        r
      in
      let key p =
        prompt p;
        let r =
          with_mode fd
            (fun t ->
              { t with Unix.c_icanon = false; c_echo = false; c_vmin = 1 })
            (fun () -> read_char fd)
        in
        write_all fd "\n";
        r
      in
      let have p = Agents.lookup ~dirs:(Agents.path_dirs ()) p <> None in
      let copy text =
        match clipboard ~macos ~ssh:(Machine_check.in_ssh ()) ~have with
        | Escape ->
            write_all fd (osc52 text);
            true
        | Program argv -> (
            let argv =
              if text = "" && argv.(0) = "wl-copy" then
                [| "wl-copy"; "--clear" |]
              else argv
            in
            match Proc.run ~timeout:10.0 ~stdin:text argv with
            | Ok { code = 0; _ } -> true
            | _ -> false)
      in
      Ok { say; ask; secret; key; copy }
