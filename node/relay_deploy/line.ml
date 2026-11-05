(* A line the daily digest carries for a relay this node deploys or judges (docs/releases.md, Relay
   releases), and what telling it records, so a line that has gone out is not carried again. The
   digest's "On your machine" section carries it (Digest_lines in the node's web library). *)

type t = { text : string; tell : unit -> unit }
