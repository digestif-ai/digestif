(* A small HTTP/1.1 server for one user on one machine: bound to 127.0.0.1, one request per
   connection, answered in turn. The UI makes a handful of requests per page, so nothing here needs
   to be concurrent; a client that stalls is cut off by the socket timeouts. *)

type request = {
  meth : string;
  target : string;
  path : string;  (** decoded segments are split later; this is the raw path *)
  query : (string * string) list;
  headers : (string * string) list;  (** names lowercased *)
  body : string;
}

type response = {
  status : int;
  headers : (string * string) list;
  body : string;
}

let reason = function
  | 200 -> "OK"
  | 201 -> "Created"
  | 204 -> "No Content"
  | 303 -> "See Other"
  | 400 -> "Bad Request"
  | 401 -> "Unauthorized"
  | 403 -> "Forbidden"
  | 404 -> "Not Found"
  | 405 -> "Method Not Allowed"
  | 413 -> "Content Too Large"
  | 422 -> "Unprocessable Content"
  | 500 -> "Internal Server Error"
  | _ -> "Status"

let max_header = 16 * 1024
let max_body = 1024 * 1024

let percent_decode s =
  let b = Buffer.create (String.length s) in
  let n = String.length s in
  let rec go i =
    if i < n then
      match s.[i] with
      | '%' when i + 2 < n -> (
          match int_of_string_opt ("0x" ^ String.sub s (i + 1) 2) with
          | Some c ->
              Buffer.add_char b (Char.chr c);
              go (i + 3)
          | None ->
              Buffer.add_char b '%';
              go (i + 1))
      | '+' ->
          Buffer.add_char b ' ';
          go (i + 1)
      | c ->
          Buffer.add_char b c;
          go (i + 1)
  in
  go 0;
  Buffer.contents b

(* Path segments decode %XX but not +: a key's base64url never holds one, and a + in a path is a +. *)
let segment_decode s =
  percent_decode (String.concat "%2B" (String.split_on_char '+' s))

let parse_query q =
  String.split_on_char '&' q
  |> List.filter (fun x -> x <> "")
  |> List.map (fun kv ->
      match String.index_opt kv '=' with
      | Some i ->
          ( percent_decode (String.sub kv 0 i),
            percent_decode (String.sub kv (i + 1) (String.length kv - i - 1)) )
      | None -> (percent_decode kv, ""))

let header (req : request) name = List.assoc_opt name req.headers

exception Bad of int

let read_request fd =
  let buf = Buffer.create 4096 in
  let chunk = Bytes.create 8192 in
  let read () =
    match Unix.read fd chunk 0 (Bytes.length chunk) with
    | 0 -> raise (Bad 400)
    | n -> Buffer.add_subbytes buf chunk 0 n
  in
  let rec head_end () =
    let s = Buffer.contents buf in
    let rec find i =
      if i + 3 >= String.length s then None
      else if String.sub s i 4 = "\r\n\r\n" then Some i
      else find (i + 1)
    in
    match find 0 with
    | Some i -> i
    | None ->
        if Buffer.length buf > max_header then raise (Bad 413);
        read ();
        head_end ()
  in
  let he = head_end () in
  let raw = Buffer.contents buf in
  let head = String.sub raw 0 he in
  let lines = String.split_on_char '\n' head |> List.map String.trim in
  let meth, target =
    match lines with
    | first :: _ -> (
        match String.split_on_char ' ' first with
        | [ m; t; _ ] -> (m, t)
        | _ -> raise (Bad 400))
    | [] -> raise (Bad 400)
  in
  let headers =
    List.filter_map
      (fun l ->
        match String.index_opt l ':' with
        | Some i ->
            Some
              ( String.lowercase_ascii (String.trim (String.sub l 0 i)),
                String.trim (String.sub l (i + 1) (String.length l - i - 1)) )
        | None -> None)
      (List.tl lines)
  in
  let length =
    match List.assoc_opt "content-length" headers with
    | Some v -> (
        match int_of_string_opt v with
        | Some n when n >= 0 && n <= max_body -> n
        | Some _ -> raise (Bad 413)
        | None -> raise (Bad 400))
    | None -> 0
  in
  if List.assoc_opt "transfer-encoding" headers <> None then raise (Bad 400);
  let rec body () =
    if Buffer.length buf - (he + 4) < length then begin
      read ();
      body ()
    end
  in
  body ();
  let body = String.sub (Buffer.contents buf) (he + 4) length in
  let path, query =
    match String.index_opt target '?' with
    | Some i ->
        ( String.sub target 0 i,
          parse_query (String.sub target (i + 1) (String.length target - i - 1))
        )
    | None -> (target, [])
  in
  { meth; target; path; query; headers; body }

let write_all fd s =
  let b = Bytes.of_string s in
  let rec go off =
    if off < Bytes.length b then
      go (off + Unix.write fd b off (Bytes.length b - off))
  in
  go 0

let send fd r =
  let headers =
    ("Content-Length", string_of_int (String.length r.body))
    :: ("Connection", "close") :: r.headers
  in
  let head =
    Printf.sprintf "HTTP/1.1 %d %s\r\n%s\r\n" r.status (reason r.status)
      (String.concat ""
         (List.map (fun (k, v) -> Printf.sprintf "%s: %s\r\n" k v) headers))
  in
  write_all fd (head ^ r.body)

let plain status text =
  {
    status;
    headers = [ ("Content-Type", "text/plain; charset=utf-8") ];
    body = text;
  }

(* Bind 127.0.0.1 only; [port] 0 takes any free port. Answers the socket and the bound port. *)
let listen ~port =
  let fd = Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt fd Unix.SO_REUSEADDR true;
  match Unix.bind fd (Unix.ADDR_INET (Unix.inet_addr_loopback, port)) with
  | () ->
      Unix.listen fd 64;
      let bound =
        match Unix.getsockname fd with Unix.ADDR_INET (_, p) -> p | _ -> port
      in
      Ok (fd, bound)
  | exception Unix.Unix_error (e, _, _) ->
      Unix.close fd;
      Error
        (Printf.sprintf "cannot listen on 127.0.0.1:%d: %s" port
           (Unix.error_message e))

let serve_one handler fd =
  match Unix.accept ~cloexec:true fd with
  | exception Unix.Unix_error ((Unix.EINTR | Unix.EAGAIN), _, _) -> ()
  | client, _ ->
      Fun.protect
        ~finally:(fun () ->
          try Unix.close client with Unix.Unix_error _ -> ())
        (fun () ->
          try
            Unix.setsockopt_float client Unix.SO_RCVTIMEO 10.0;
            Unix.setsockopt_float client Unix.SO_SNDTIMEO 10.0;
            let response =
              match read_request client with
              | req -> (
                  try handler req
                  with e ->
                    prerr_endline
                      ("digestif ui: " ^ req.meth ^ " " ^ req.path ^ ": "
                     ^ Printexc.to_string e);
                    plain 500 "The node failed to answer.")
              | exception Bad status -> plain status (reason status)
            in
            send client response
          with Unix.Unix_error _ | Sys_error _ -> ())

(* Answer requests until [stop] says so; the accept wakes at least once a second to ask. *)
let run ~stop handler fd =
  while not (stop ()) do
    match Unix.select [ fd ] [] [] 1.0 with
    | [], _, _ -> ()
    | _ -> serve_one handler fd
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> ()
  done
