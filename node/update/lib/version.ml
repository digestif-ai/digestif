(* A release version: MAJOR.MINOR.PATCH, decimal, no leading zeros, nothing after. *)

type t = { major : int; minor : int; patch : int }

let to_string v = Printf.sprintf "%d.%d.%d" v.major v.minor v.patch

let component s =
  let ok =
    s <> ""
    && String.for_all (function '0' .. '9' -> true | _ -> false) s
    && (s = "0" || s.[0] <> '0')
    && String.length s <= 9
  in
  if ok then Some (int_of_string s) else None

let of_string s =
  match String.split_on_char '.' s with
  | [ a; b; c ] -> (
      match (component a, component b, component c) with
      | Some major, Some minor, Some patch -> Ok { major; minor; patch }
      | _ -> Error (Printf.sprintf "version %S is not MAJOR.MINOR.PATCH" s))
  | _ -> Error (Printf.sprintf "version %S is not MAJOR.MINOR.PATCH" s)

let compare a b =
  match Int.compare a.major b.major with
  | 0 -> (
      match Int.compare a.minor b.minor with
      | 0 -> Int.compare a.patch b.patch
      | c -> c)
  | c -> c

let equal a b = compare a b = 0
