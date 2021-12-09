(* missing_blocks_auditor.ml -- report missing blocks from an archive db *)

open Core_kernel
open Async

(* prime numbers; multiply by them to derive error exit code
   check divisibility by any one of them to see if a particular error occurred
*)
let no_error = 1

let missing_blocks_error = 2

let pending_blocks_error = 3

let chain_length_error = 5

let chain_status_error = 7

let add_error, get_error_exit =
  let error_exit = ref no_error in
  let add_error n =
    (* multiply by n, if n not already a factor *)
    if !error_exit mod n > 0 then error_exit := !error_exit * n
  in
  let get_error_exit () = !error_exit in
  (add_error, get_error_exit)

let main ~archive_uri () =
  let logger = Logger.create () in
  let archive_uri = Uri.of_string archive_uri in
  match Caqti_async.connect_pool ~max_size:128 archive_uri with
  | Error e ->
      [%log fatal]
        ~metadata:[ ("error", `String (Caqti_error.show e)) ]
        "Failed to create a Caqti pool for Postgresql" ;
      exit 1
  | Ok pool ->
      [%log info] "Successfully created Caqti pool for Postgresql" ;
      [%log info] "Querying missing blocks" ;
      let%bind missing_blocks_raw =
        match%bind
          Caqti_async.Pool.use (fun db -> Sql.Unparented_blocks.run db ()) pool
        with
        | Ok blocks ->
            return blocks
        | Error msg ->
            [%log error] "Error getting missing blocks"
              ~metadata:[ ("error", `String (Caqti_error.show msg)) ] ;
            exit 1
      in
      (* filter out genesis block *)
      let missing_blocks =
        List.filter missing_blocks_raw ~f:(fun (_, _, height, _) -> height <> 1)
      in
      if List.is_empty missing_blocks then
        [%log info] "There are no missing blocks in the archive db"
      else (
        add_error missing_blocks_error ;
        List.iter missing_blocks
          ~f:(fun (block_id, state_hash, height, parent_hash) ->
            if height > 1 then
              [%log info] "Block has no parent in archive db"
                ~metadata:
                  [ ("block_id", `Int block_id)
                  ; ("state_hash", `String state_hash)
                  ; ("height", `Int height)
                  ; ("parent_hash", `String parent_hash)
                  ; ("parent_height", `Int (height - 1))
                  ]) ) ;
      [%log info] "Querying for gaps in chain statuses" ;
      let%bind highest_canonical =
        match%bind
          Caqti_async.Pool.use
            (fun db -> Sql.Chain_status.run_highest_canonical db ())
            pool
        with
        | Ok height ->
            return height
        | Error msg ->
            [%log error] "Error getting greatest height of canonical blocks"
              ~metadata:[ ("error", `String (Caqti_error.show msg)) ] ;
            exit 1
      in
      let%bind pending_below =
        match%bind
          Caqti_async.Pool.use
            (fun db ->
              Sql.Chain_status.run_count_pending_below db highest_canonical)
            pool
        with
        | Ok count ->
            return count
        | Error msg ->
            [%log error]
              "Error getting number of pending blocks below highest canonical \
               block"
              ~metadata:[ ("error", `String (Caqti_error.show msg)) ] ;
            exit 1
      in
      if Int64.equal pending_below Int64.zero then
        [%log info] "There are no gaps in the chain statuses"
      else (
        add_error pending_blocks_error ;
        [%log info]
          "There are $num_pending_blocks_below pending blocks lower than the \
           highest canonical block"
          ~metadata:
            [ ( "max_height_canonical_block"
              , `String (Int64.to_string highest_canonical) )
            ; ( "num_pending_blocks_below"
              , `String (Int64.to_string pending_below) )
            ] ) ;
      let%bind canonical_chain =
        match%bind
          Caqti_async.Pool.use
            (fun db ->
              Sql.Chain_status.run_canonical_chain db highest_canonical)
            pool
        with
        | Ok chain ->
            return chain
        | Error msg ->
            [%log error] "Error getting canonical chain"
              ~metadata:[ ("error", `String (Caqti_error.show msg)) ] ;
            exit 1
      in
      let chain_len = List.length canonical_chain |> Int64.of_int in
      if Int64.equal chain_len highest_canonical then
        [%log info] "Length of canonical chain is %Ld blocks" chain_len
      else (
        add_error chain_length_error ;
        [%log info] "Length of canonical chain is %Ld blocks, expected: %Ld"
          chain_len highest_canonical ) ;
      let invalid_chain =
        List.filter canonical_chain
          ~f:(fun (_block_id, _state_hash, chain_status) ->
            not (String.equal chain_status "canonical"))
      in
      if List.is_empty invalid_chain then
        [%log info]
          "All blocks along the canonical chain have a valid chain status"
      else add_error chain_status_error ;
      List.iter invalid_chain ~f:(fun (block_id, state_hash, chain_status) ->
          [%log info]
            "Canonical block has a chain_status other than \"canonical\""
            ~metadata:
              [ ("block_id", `Int block_id)
              ; ("state_hash", `String state_hash)
              ; ("chain_status", `String chain_status)
              ]) ;
      let error_exit = get_error_exit () in
      if error_exit <> no_error then Core.exit error_exit else Core.exit 0

let () =
  Command.(
    run
      (let open Let_syntax in
      Command.async
        ~summary:"Report state hashes of blocks missing from archive database"
        (let%map archive_uri =
           Param.flag "--archive-uri"
             ~doc:
               "URI URI for connecting to the archive database (e.g., \
                postgres://$USER@localhost:5432/archiver)"
             Param.(required string)
         in
         main ~archive_uri)))
